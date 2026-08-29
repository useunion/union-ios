import XCTest
@testable import Union

final class TimerTests: XCTestCase {
    /// The periodic timer must flush without any further SDK call (a cold start that only emits auto events).
    func testPeriodicTimerFlushesQueuedEvents() async throws {
        let transport = StubTransport()
        let p = EventPipeline(
            config: PipelineConfig(writeKey: "k", environment: .production, privacyMode: .productAnalytics, flushAt: 100, flushInterval: 0.2, maxQueuedEvents: 100),
            store: InMemoryEventStore(), transport: transport, identityStore: InMemoryIdentityStore(), kv: InMemoryKeyValueStore(),
            clock: SystemClock(), logger: SDKLogger(level: .none, handler: nil), device: Fixtures.device
        )
        await p.start(hadPersistentIdentity: false)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(transport.sent.count, 1, "timer should have flushed once")
        XCTAssertEqual(transport.sent.first?.events.map(\.name), ["$first_open", "$app_install", "$session_start"])
    }
}
