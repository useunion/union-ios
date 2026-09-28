import Foundation
@testable import Union

final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) { lock.lock(); _now = _now.addingTimeInterval(seconds); lock.unlock() }
}

/// Scripted transport: pops responses in order; records every sent batch.
final class StubTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [TransportResponse]
    private(set) var sent: [EventBatch] = []
    var failWithNetworkError = false

    init(_ responses: [TransportResponse] = []) { self.responses = responses }

    func enqueue(_ response: TransportResponse) { lock.withLock { responses.append(response) } }

    func send(_ body: Data, writeKey: String) async throws -> TransportResponse {
        let batch = try WireCoding.decoder.decode(EventBatch.self, from: body)
        return try lock.withLock {
            sent.append(batch)
            if failWithNetworkError { throw URLError(.notConnectedToInternet) }
            return responses.isEmpty ? .accepted() : responses.removeFirst()
        }
    }
}

/// Holds the first `send` until `release()`, so a test can act while a flush is suspended in it.
final class GatedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false
    private var held = false
    private var released = false
    private(set) var sent: [EventBatch] = []

    func send(_ body: Data, writeKey: String) async throws -> TransportResponse {
        let batch = try WireCoding.decoder.decode(EventBatch.self, from: body)
        let first = lock.withLock { () -> Bool in
            defer { holding = true }
            return !holding
        }
        if first {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    held = true
                    if released { return true }
                    gate = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
        lock.withLock { sent.append(batch) }
        return .accepted()
    }

    func waitUntilHeld() async {
        while !lock.withLock({ held }) { await Task.yield() }
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        c?.resume()
    }
}

extension TransportResponse {
    static func accepted(rejected: Int = 0) -> TransportResponse {
        TransportResponse(status: 202, body: Data("{\"accepted\":1,\"rejected\":\(rejected),\"batch_id\":\"b\"}".utf8), retryAfter: nil)
    }
    static func error(_ status: Int, _ json: String, retryAfter: TimeInterval? = nil) -> TransportResponse {
        TransportResponse(status: status, body: Data(json.utf8), retryAfter: retryAfter)
    }
}

enum Fixtures {
    static let device = DeviceContext(appVersion: "2.4.0", appBuild: "240", sdkVersion: SDKInfo.version, osVersion: "18.1", deviceModel: "iPhone16,1", locale: "pl-PL", timezone: "Europe/Warsaw")

    static func pipeline(clock: TestClock = TestClock(), transport: any Transport = StubTransport(), privacy: PrivacyMode = .productAnalytics, flushAt: Int = 100, analyticsCollectionEnabled: Bool = true, kv: KeyValueStore = InMemoryKeyValueStore(), identity: IdentityStore = InMemoryIdentityStore()) -> EventPipeline {
        EventPipeline(
            config: PipelineConfig(writeKey: "test", environment: .production, privacyMode: privacy, flushAt: flushAt, flushInterval: 3600, maxQueuedEvents: 50, analyticsCollectionEnabled: analyticsCollectionEnabled),
            store: InMemoryEventStore(), transport: transport, identity: IdentityCoordinator(store: identity, privacyMode: privacy), kv: kv, clock: clock,
            logger: SDKLogger(level: .none, handler: nil), device: device
        )
    }

    static func crashSchemaData() throws -> Data {
        let url = Bundle.module.url(forResource: "crash-batch.v1", withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    static func schemaData() throws -> Data {
        let url = Bundle.module.url(forResource: "event-batch.v1", withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }
}

/// Counts what it is asked for, so a test can assert that nothing asked during construction.
final class CountingIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity = Identity()
    private(set) var loads = 0
    private(set) var saves = 0

    func load() -> Identity {
        lock.lock(); defer { lock.unlock() }
        loads += 1
        return identity
    }

    func save(_ identity: Identity) {
        lock.lock(); defer { lock.unlock() }
        saves += 1
        self.identity = identity
    }

    func wipe() { save(Identity()) }
}
