import XCTest
@testable import Union

/// Talks to a real ingest. Skipped unless AV_INTEGRATION_WRITE_KEY is set, e.g.
///   AV_INTEGRATION_WRITE_KEY=av_… AV_INTEGRATION_ENDPOINT=https://…/v1/batch swift test --filter IntegrationTests
final class IntegrationTests: XCTestCase {
    func testRealIngestAcceptsBatch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AV_INTEGRATION_WRITE_KEY"] else { throw XCTSkip("AV_INTEGRATION_WRITE_KEY not set") }
        let endpoint = URL(string: env["AV_INTEGRATION_ENDPOINT"] ?? "https://union-ingest.office-927.workers.dev/v1/batch")!

        let transport = URLSessionTransport(endpoint: endpoint)
        let p = EventPipeline(
            config: PipelineConfig(writeKey: key, environment: .production, privacyMode: .productAnalytics, flushAt: 100, flushInterval: 3600, maxQueuedEvents: 100),
            store: InMemoryEventStore(), transport: transport, identityStore: InMemoryIdentityStore(), kv: InMemoryKeyValueStore(),
            clock: SystemClock(), logger: SDKLogger(level: .debug, handler: { print("[AV \($0)] \($1)") }), device: Fixtures.device
        )
        await p.start(hadPersistentIdentity: false)
        await p.screen(name: "Home", properties: [:])
        await p.track(name: "workout_viewed", properties: [:], role: .discovery, screen: "WorkoutDetail")
        await p.track(name: "workout_started", properties: ["plan": "strength", "minutes": 30], role: .start, screen: "WorkoutDetail")
        await p.track(name: "workout_finished", properties: [:], role: .success, screen: "WorkoutSummary")
        await p.flush()

        let left = await p.queuedEvents
        XCTAssertTrue(left.isEmpty, "ingest should have accepted the batch; left: \(left.map(\.name))")
        let stopped = await p.isStopped
        XCTAssertFalse(stopped)
    }
}
