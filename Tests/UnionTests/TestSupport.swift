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

    static func pipeline(clock: TestClock = TestClock(), transport: StubTransport = StubTransport(), privacy: PrivacyMode = .productAnalytics, flushAt: Int = 100, kv: KeyValueStore = InMemoryKeyValueStore(), identity: IdentityStore = InMemoryIdentityStore()) -> EventPipeline {
        EventPipeline(
            config: PipelineConfig(writeKey: "test", environment: .production, privacyMode: privacy, flushAt: flushAt, flushInterval: 3600, maxQueuedEvents: 50),
            store: InMemoryEventStore(), transport: transport, identityStore: identity, kv: kv, clock: clock,
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
