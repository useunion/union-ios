import XCTest
#if canImport(StoreKit)
import StoreKit
#endif
@testable import Union

final class EnvironmentTests: XCTestCase {
    #if canImport(StoreKit)
    func testStoreKitEnvironmentsMapOntoTheWireEnvironments() {
        XCTAssertEqual(EnvironmentDetector.environment(for: .production), .production)
        XCTAssertEqual(EnvironmentDetector.environment(for: .sandbox), .testflight)
        XCTAssertEqual(EnvironmentDetector.environment(for: .xcode), .development)
    }
    #endif

    /// With one write key for every build, the environment the envelope carries is the only thing
    /// separating TestFlight from the App Store numbers — so StoreKit's late answer must reach it,
    /// including for events queued before the answer came.
    func testARefinedEnvironmentReachesTheNextBatch() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        await p.track(name: "queued_before", properties: [:], role: nil, screen: nil)
        await p.setEnvironment(.testflight)
        await p.flush()

        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].environment, .testflight)
    }
}
