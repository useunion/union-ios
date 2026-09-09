import XCTest
@testable import Union

final class UUIDv7Tests: XCTestCase {
    func testFormatVersionAndVariant() {
        let id = UUIDv7.generate()
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id[id.index(id.startIndex, offsetBy: 14)], "7")
        XCTAssertTrue("89ab".contains(id[id.index(id.startIndex, offsetBy: 19)]))
    }

    func testTimeOrderedAndUnique() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = UUIDv7.generate(now: t)
        let b = UUIDv7.generate(now: t)
        let c = UUIDv7.generate(now: t.addingTimeInterval(1))
        XCTAssertNotEqual(a, b)
        XCTAssertLessThan(a, b, "same-ms ids stay monotonic")
        XCTAssertLessThan(b, c)
    }
}

final class ValidationTests: XCTestCase {
    func testNames() {
        XCTAssertNoThrow(try Validation.validateCustomName("workout_started"))
        XCTAssertThrowsError(try Validation.validateCustomName("WorkoutStarted"))
        XCTAssertThrowsError(try Validation.validateCustomName("$screen_view"))
        XCTAssertThrowsError(try Validation.validateCustomName("1abc"))
        XCTAssertThrowsError(try Validation.validateCustomName(String(repeating: "a", count: 65)))
    }

    func testProperties() {
        XCTAssertNoThrow(try Validation.validate(properties: ["plan": "strength", "minutes": 30, "premium": true]))
        XCTAssertThrowsError(try Validation.validate(properties: ["long": .string(String(repeating: "x", count: 257))]))
        XCTAssertThrowsError(try Validation.validate(properties: ["nan": .number(.nan)]))
        let many = Dictionary(uniqueKeysWithValues: (0..<33).map { ("k\($0)", PropertyValue.number(1)) })
        XCTAssertThrowsError(try Validation.validate(properties: many))
    }

    /// LIMITS mirror must match the contract's schema fixture.
    func testLimitsMatchSchema() throws {
        let root = try JSONSerialization.jsonObject(with: Fixtures.schemaData()) as! [String: Any]
        let defs = root["definitions"] as! [String: Any]
        let batch = defs["EventBatchV1"] as! [String: Any]
        let props = batch["properties"] as! [String: Any]
        let events = props["events"] as! [String: Any]
        XCTAssertEqual(events["maxItems"] as? Int, Limits.batchMaxEvents)
        let event = events["items"] as! [String: Any]
        let eventProps = event["properties"] as! [String: Any]
        let name = eventProps["name"] as! [String: Any]
        let custom = (name["anyOf"] as! [[String: Any]]).first { $0["pattern"] != nil }!
        XCTAssertEqual(custom["pattern"] as? String, Limits.eventNamePattern)
        XCTAssertEqual(custom["maxLength"] as? Int, Limits.eventNameMaxLength)
        XCTAssertEqual((eventProps["screen"] as! [String: Any])["maxLength"] as? Int, Limits.screenNameMaxLength)
        let feature = eventProps["feature"] as! [String: Any]
        XCTAssertEqual(feature["maxLength"] as? Int, Limits.featureKeyMaxLength)
        XCTAssertEqual(feature["pattern"] as? String, Limits.featureKeyPattern)

        let identity = (props["identity"] as! [String: Any])["properties"] as! [String: Any]
        XCTAssertEqual((identity["user_id"] as! [String: Any])["maxLength"] as? Int, Limits.userIdMaxLength)
        let traits = identity["traits"] as! [String: Any]
        XCTAssertEqual(traits["maxProperties"] as? Int, Limits.maxTraits)
        XCTAssertEqual((traits["propertyNames"] as! [String: Any])["maxLength"] as? Int, Limits.traitKeyMaxLength)
        XCTAssertEqual((traits["additionalProperties"] as! [String: Any])["maxLength"] as? Int, Limits.traitValueMaxLength)
    }

    func testPropertyValueEncodesIntegersWithoutFraction() throws {
        let data = try WireCoding.encoder.encode(["minutes": PropertyValue.number(30), "ratio": .number(0.5), "ok": .bool(true)])
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"minutes\":30"), s)
        XCTAssertTrue(s.contains("\"ratio\":0.5"), s)
        XCTAssertTrue(s.contains("\"ok\":true"), s)
    }
}

final class SessionTests: XCTestCase {
    func testContinuesWithin30MinutesAndRotatesAfter() {
        let clock = TestClock()
        var sm = SessionManager(clock: clock, store: InMemoryKeyValueStore())
        guard case .rotated(let ended, let first) = sm.touch() else { return XCTFail() }
        XCTAssertNil(ended)
        clock.advance(29 * 60)
        XCTAssertEqual(sm.touch(), .continued(sessionId: first.sessionId))
        clock.advance(31 * 60)
        guard case .rotated(let ended2, let second) = sm.touch() else { return XCTFail("expected rotation") }
        XCTAssertEqual(ended2?.sessionId, first.sessionId)
        XCTAssertNotEqual(second.sessionId, first.sessionId)
    }

    func testSnapshotSurvivesRelaunch() {
        let clock = TestClock()
        let kv = InMemoryKeyValueStore()
        var a = SessionManager(clock: clock, store: kv)
        _ = a.touch()
        clock.advance(60)
        var b = SessionManager(clock: clock, store: kv) // "relaunch"
        XCTAssertEqual(b.touch(), .continued(sessionId: a.current!.sessionId))
    }

    func testInstallDetection() {
        let kv = InMemoryKeyValueStore()
        XCTAssertEqual(InstallState.evaluate(store: kv, device: Fixtures.device, hadPersistentIdentity: false), .firstOpen(reinstall: false))
        XCTAssertEqual(InstallState.evaluate(store: kv, device: Fixtures.device, hadPersistentIdentity: false), .unchanged)
        var d = Fixtures.device
        d.appVersion = "2.5.0"; d.appBuild = "250"
        XCTAssertEqual(InstallState.evaluate(store: kv, device: d, hadPersistentIdentity: false), .updated(previousVersion: "2.4.0", previousBuild: "240"))
        XCTAssertEqual(InstallState.evaluate(store: InMemoryKeyValueStore(), device: d, hadPersistentIdentity: true), .firstOpen(reinstall: true))
    }
}
