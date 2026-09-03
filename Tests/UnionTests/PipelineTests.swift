import XCTest
@testable import Union

final class PipelineTests: XCTestCase {
    func testColdStartEmitsInstallAndSessionStartAndBatchConformsToSchema() async throws {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        await p.track(name: "workout_started", properties: ["plan": "strength", "minutes": 30], role: .start, screen: "WorkoutDetail")
        await p.flush()

        XCTAssertEqual(transport.sent.count, 1)
        let batch = transport.sent[0]
        XCTAssertEqual(batch.events.map(\.name), ["$first_open", "$app_install", "$session_start", "workout_started"])
        XCTAssertEqual(Set(batch.events.map(\.sessionId)).count, 1)
        XCTAssertNotNil(batch.identity.installId)
        XCTAssertEqual(batch.contractVersion, 1)

        let validator = try MiniSchemaValidator(schema: Fixtures.schemaData())
        let errors = try validator.validate(WireCoding.encoder.encode(batch))
        XCTAssertEqual(errors, [], errors.joined(separator: "\n"))
        let queued = await p.queuedEvents
        XCTAssertTrue(queued.isEmpty, "acknowledged events leave the queue")
    }

    func testStrictAnonymousSendsEmptyIdentityAndIgnoresIdentify() async throws {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport, privacy: .strictAnonymous)
        await p.start(hadPersistentIdentity: false)
        await p.identify(userId: "u1")
        await p.flush()
        let batch = transport.sent[0]
        XCTAssertEqual(batch.identity, .anonymous)
        let json = String(decoding: try WireCoding.encoder.encode(batch), as: UTF8.self)
        XCTAssertTrue(json.contains("\"identity\":{}"), json)
        XCTAssertFalse(json.contains("install_id"))
    }

    func testInvalidEventsAreDroppedLocallyAndNeverSent() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.track(name: "BadName", properties: [:], role: nil, screen: nil)
        await p.track(name: "$session_start", properties: [:], role: nil, screen: nil)
        await p.flush()
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testPartialRejectionDropsOnlyFlaggedEventsAndRetriesRestWithSameIds() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p.track(name: "b_two", properties: [:], role: nil, screen: nil)
        await p.track(name: "c_three", properties: [:], role: nil, screen: nil)
        // The queue also holds the auto-emitted $session_start; the server flags b_two by its index in the batch.
        let queued = await p.queuedEvents
        let badIndex = queued.firstIndex { $0.name == "b_two" }!
        transport.enqueue(.error(400, #"{"error":"invalid_batch","message":"batch rejected","details":[{"path":"events.\#(badIndex).properties.x","message":"too long"}]}"#))
        transport.enqueue(.accepted())
        await p.flush()
        XCTAssertEqual(transport.sent.count, 2)
        let first = transport.sent[0].events
        let second = transport.sent[1].events
        XCTAssertEqual(second.map(\.name), first.map(\.name).filter { $0 != "b_two" })
        XCTAssertEqual(second.map(\.eventId), first.filter { $0.name != "b_two" }.map(\.eventId), "retried events keep their event_id (server dedupe)")
        let left = await p.queuedEvents
        XCTAssertTrue(left.isEmpty)
    }

    func testEnvelopeProblemDropsWholeBatch() async {
        let env = #"{"error":"invalid_batch","message":"write key is bound to production"}"#
        let transport = StubTransport([.error(400, env)])
        let p = Fixtures.pipeline(transport: transport)
        await p.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p.flush()
        let queued = await p.queuedEvents
        XCTAssertTrue(queued.isEmpty)
    }

    func testUnauthorizedStopsAndRateLimitPauses() async {
        let t1 = StubTransport([.error(401, #"{"error":"invalid_write_key","message":"unknown"}"#)])
        let p1 = Fixtures.pipeline(transport: t1)
        await p1.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p1.flush()
        let stopped = await p1.isStopped
        XCTAssertTrue(stopped)

        let clock = TestClock()
        let t2 = StubTransport([.error(429, #"{"error":"rate_limited","message":"slow down"}"#, retryAfter: 60), .accepted()])
        let p2 = Fixtures.pipeline(clock: clock, transport: t2)
        await p2.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p2.flush()
        var paused = await p2.isPaused
        XCTAssertTrue(paused)
        await p2.flush()
        XCTAssertEqual(t2.sent.count, 1, "no send while paused")
        clock.advance(61)
        await p2.flush()
        paused = await p2.isPaused
        XCTAssertFalse(paused)
        XCTAssertEqual(t2.sent.count, 2)
    }

    func testNetworkErrorKeepsQueueAndBacksOff() async {
        let clock = TestClock()
        let transport = StubTransport()
        transport.failWithNetworkError = true
        let p = Fixtures.pipeline(clock: clock, transport: transport)
        await p.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p.flush()
        let queued = await p.queuedEvents
        XCTAssertTrue(queued.contains { $0.name == "a_one" }, "nothing is lost on network failure")
        XCTAssertEqual(transport.sent.count, 1)
        let paused = await p.isPaused
        XCTAssertTrue(paused)
    }

    func testSessionRotatesAfterLongBackground() async {
        let clock = TestClock()
        let transport = StubTransport()
        let p = Fixtures.pipeline(clock: clock, transport: transport)
        await p.start(hadPersistentIdentity: false)
        let first = await p.currentSessionId
        await p.didEnterBackground()
        clock.advance(31 * 60)
        await p.willEnterForeground()
        let second = await p.currentSessionId
        XCTAssertNotEqual(first, second)
        await p.flush()
        let names = transport.sent.flatMap { $0.events.map(\.name) }
        XCTAssertTrue(names.contains("$background"))
        XCTAssertTrue(names.contains("$session_end"))
        XCTAssertEqual(names.filter { $0 == "$session_start" }.count, 2)
    }

    /// Host apps call reset() on a cold launch before their own auth restores (Hook did); rotating there
    /// split the launch into two sessions, one holding $app_update and none of the screens.
    func testResetWithoutUserIdKeepsTheSession() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        let first = await p.currentSessionId
        await p.reset()
        let after = await p.currentSessionId
        XCTAssertEqual(first, after)
        await p.flush()
        let names = transport.sent.flatMap { $0.events.map(\.name) }
        XCTAssertFalse(names.contains("$session_end"))
        XCTAssertEqual(names.filter { $0 == "$session_start" }.count, 1)
    }

    func testResetAfterIdentifyRotatesTheSession() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        let first = await p.currentSessionId
        await p.identify(userId: "u-1")
        await p.reset()
        let after = await p.currentSessionId
        XCTAssertNotEqual(first, after)
        await p.flush()
        let names = transport.sent.flatMap { $0.events.map(\.name) }
        XCTAssertTrue(names.contains("$session_end"))
        XCTAssertEqual(names.filter { $0 == "$session_start" }.count, 2)
    }

    func testOptOutWipesAndStops() async {
        let transport = StubTransport()
        let kv = InMemoryKeyValueStore()
        let p = Fixtures.pipeline(transport: transport, kv: kv)
        await p.start(hadPersistentIdentity: false)
        await p.optOut()
        await p.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p.flush()
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(kv.string(forKey: "opt_out"), "1")
        let id = await p.currentIdentity
        XCTAssertEqual(id, .anonymous)
    }

    func testScreenViewCarriesTheScreenNameAndItsProperties() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        await p.screen(name: "WorkoutDetail", properties: ["plan": .string("strength")])
        await p.screen(name: String(repeating: "x", count: Limits.screenNameMaxLength + 1), properties: [:])
        await p.flush()

        let views = transport.sent[0].events.filter { $0.name == "$screen_view" }
        XCTAssertEqual(views.count, 1, "a screen name over the limit is dropped, not truncated")
        XCTAssertEqual(views[0].screen, "WorkoutDetail")
        XCTAssertEqual(views[0].properties?["plan"], .string("strength"))
    }

    func testDeepLinkReportsSchemeHostAndPathButNeverTheQuery() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        await p.deepLink(URL(string: "hook://open/workout/42?token=secret&email=a@b.com#frag")!)
        await p.flush()

        let event = transport.sent[0].events.first { $0.name == "$deep_link" }
        XCTAssertEqual(event?.properties?["url_scheme"], .string("hook"))
        XCTAssertEqual(event?.properties?["host"], .string("open"))
        XCTAssertEqual(event?.properties?["path"], .string("/workout/42"))
        let json = String(decoding: try! WireCoding.encoder.encode(transport.sent[0]), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"), "query strings are PII and never leave the device")
        XCTAssertFalse(json.contains("frag"))
    }

    func testForegroundWithinTheWindowContinuesTheSession() async {
        let clock = TestClock()
        let transport = StubTransport()
        let p = Fixtures.pipeline(clock: clock, transport: transport)
        await p.start(hadPersistentIdentity: false)
        let session = await p.currentSessionId
        await p.didEnterBackground()
        clock.advance(60)
        await p.willEnterForeground()
        await p.flush()

        let same = await p.currentSessionId
        XCTAssertEqual(same, session, "a minute in the background is not a new session")
        let names = transport.sent.flatMap { $0.events.map(\.name) }
        XCTAssertEqual(names.filter { $0 == "$foreground" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "$session_start" }.count, 1)
        XCTAssertFalse(names.contains("$session_end"))
    }

    func testTooLargeSplitsTheBatchInsteadOfDroppingIt() async {
        let transport = StubTransport([.error(413, #"{"error":"batch_too_large","message":"256 KB max"}"#)])
        let p = Fixtures.pipeline(transport: transport)
        for i in 0..<4 { await p.track(name: "e_\(i)", properties: [:], role: nil, screen: nil) }
        await p.flush()

        XCTAssertEqual(transport.sent.count, 2, "the rejected batch is resent, halved, not dropped")
        XCTAssertLessThan(transport.sent[1].events.count, Limits.batchMaxEvents)
        let queued = await p.queuedEvents
        XCTAssertTrue(queued.isEmpty)
    }

    func testDisabledProjectPausesForAnHourAndKeepsTheQueue() async {
        let clock = TestClock()
        let transport = StubTransport([.error(403, #"{"error":"project_disabled","message":"disabled"}"#), .accepted()])
        let p = Fixtures.pipeline(clock: clock, transport: transport)
        await p.track(name: "a_one", properties: [:], role: nil, screen: nil)
        await p.flush()

        var paused = await p.isPaused
        XCTAssertTrue(paused)
        var queued = await p.queuedEvents
        XCTAssertTrue(queued.contains { $0.name == "a_one" }, "nothing is lost while the project is disabled")
        clock.advance(3600 + 1)
        paused = await p.isPaused
        XCTAssertFalse(paused)
        await p.flush()
        XCTAssertEqual(transport.sent.count, 2)
        queued = await p.queuedEvents
        XCTAssertTrue(queued.isEmpty)
    }

    func testIdentifyMergesTraitsAndSendsThemWithEveryBatch() async throws {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        await p.identify(userId: "u-1", traits: ["email": "ada@example.com", "name": "Ada"])
        await p.identify(userId: "u-1", traits: ["plan": "pro"])
        await p.flush()

        let identity = transport.sent[0].identity
        XCTAssertEqual(identity.userId, "u-1")
        XCTAssertEqual(identity.traits, ["email": "ada@example.com", "name": "Ada", "plan": "pro"],
                       "a later identify adds traits, it does not replace the set")

        let validator = try MiniSchemaValidator(schema: Fixtures.schemaData())
        let errors = try validator.validate(WireCoding.encoder.encode(transport.sent[0]))
        XCTAssertEqual(errors, [], errors.joined(separator: "\n"))
    }

    func testInvalidTraitsLeaveTheIdentityUntouched() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.identify(userId: "u-1", traits: ["email": "ada@example.com"])
        await p.identify(userId: "u-1", traits: ["bio": String(repeating: "x", count: Limits.traitValueMaxLength + 1)])
        await p.identify(userId: "u-1", traits: Dictionary(uniqueKeysWithValues: (0...Limits.maxTraits).map { ("k\($0)", "v") }))
        await p.identify(userId: "u-1", traits: ["": "v"])

        let identity = await p.currentIdentity
        XCTAssertEqual(identity.traits, ["email": "ada@example.com"], "a rejected call changes nothing")
    }

    func testStrictAnonymousNeverSendsTraits() async throws {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport, privacy: .strictAnonymous)
        await p.start(hadPersistentIdentity: false)
        await p.identify(userId: "u-1", traits: ["email": "ada@example.com"])
        await p.flush()

        XCTAssertEqual(transport.sent[0].identity, .anonymous)
        let json = String(decoding: try WireCoding.encoder.encode(transport.sent[0]), as: UTF8.self)
        XCTAssertFalse(json.contains("ada@example.com"))
        XCTAssertTrue(json.contains("\"identity\":{}"), json)
    }

    func testResetForgetsTheTraitsWithTheUser() async {
        let transport = StubTransport()
        let p = Fixtures.pipeline(transport: transport)
        await p.start(hadPersistentIdentity: false)
        await p.identify(userId: "u-1", traits: ["email": "ada@example.com"])
        await p.reset()
        await p.flush()

        let identity = transport.sent[0].identity
        XCTAssertNil(identity.traits, "logging out forgets who the person was")
        XCTAssertNil(identity.userId)
        XCTAssertNotNil(identity.installId, "the install id survives: it identifies the device, not the person")
    }

    func testTraitsSurviveARelaunch() async {
        let store = InMemoryIdentityStore()
        let first = Fixtures.pipeline(identity: store)
        await first.identify(userId: "u-1", traits: ["email": "ada@example.com"])

        let transport = StubTransport()
        let second = Fixtures.pipeline(transport: transport, identity: store)
        await second.start(hadPersistentIdentity: true)
        await second.flush()
        XCTAssertEqual(transport.sent[0].identity.traits, ["email": "ada@example.com"])
    }

    /// `Union.installId` reads straight from the identity store, so these two cases are
    /// the whole contract of that accessor: a real store hands back the minted id, and
    /// `strictAnonymous` has nothing to hand back.
    func testIdentityStoreExposesTheMintedInstallIdForServerEvents() async {
        let store = InMemoryIdentityStore()
        _ = Fixtures.pipeline(identity: store)

        let installId = store.load().installId
        XCTAssertNotNil(installId, "the id a backend needs for /v1/server is minted during init")
        XCTAssertEqual(installId, store.load().installId, "and it is stable across reads")
    }

    func testStrictAnonymousExposesNoInstallId() async {
        let store = InMemoryIdentityStore()
        store.save(Identity(installId: UUIDv7.generate(), userId: nil, traits: nil))

        _ = Fixtures.pipeline(privacy: .strictAnonymous, identity: store)

        XCTAssertNil(store.load().installId, "strict_anonymous wipes identity, so there is no id to forward")
    }

    func testBatcherRespectsLimits() {
        let big = Event(eventId: UUIDv7.generate(), sessionId: UUIDv7.generate(), name: "x", timestamp: 0, screen: nil, properties: ["p": .string(String(repeating: "a", count: 250))], role: nil)
        let queue = Array(repeating: big, count: 1500)
        let batch = Batcher.nextBatch(from: queue)
        XCTAssertLessThanOrEqual(batch.count, 100)
        let bytes = try! WireCoding.encoder.encode(batch).count
        XCTAssertLessThanOrEqual(bytes, Limits.batchMaxBytes)
        XCTAssertEqual(Batcher.nextBatch(from: [big], maxBytes: 10).count, 1, "oversized single event is still sent alone")
    }
}
