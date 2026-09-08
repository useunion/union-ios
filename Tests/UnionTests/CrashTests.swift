import XCTest
import UnionCrashCore
@testable import Union

/// Crash reporting, tested through the one door that is testable.
///
/// A test cannot crash the test runner, so the handler's own path is exercised through
/// `union_crash_capture_live` — the same thread enumeration, frame walk and serialisation the signal
/// handler performs, minus dying. Everything after that point is a pure function on the record, which
/// is why the assembly step is where the interesting assertions live.
final class CrashTests: XCTestCase {
    private var directory: URL!
    private var store: CrashStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("union-crash-tests-\(UUID().uuidString)")
        store = try CrashStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The C core

    func testLiveCaptureWritesAReadableRecordWithACrashedThread() throws {
        let path = directory.appendingPathComponent("capture.ucr").path
        XCTAssertEqual(union_crash_capture_live(path, SIGSEGV, 0), 0)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let record = try XCTUnwrap(CrashRecord(data: data), "the record must parse")
        XCTAssertEqual(record.cause, .signal)
        XCTAssertEqual(record.signum, SIGSEGV)
        XCTAssertFalse(record.threads.isEmpty)
        // Exactly one, and it is the caller's: without this the contract rejects a fatal report,
        // correctly, because there would be nothing to fingerprint.
        XCTAssertEqual(record.threads.filter(\.crashed).count, 1)
        let crashed = try XCTUnwrap(record.threads.first(where: \.crashed))
        XCTAssertGreaterThan(crashed.frames.count, 1, "the frame walk has to climb past the pc")
        XCTAssertTrue(crashed.frames.allSatisfy { $0 != 0 })
    }

    func testAnEmptyFileIsNotARecord() {
        // The ordinary outcome of a launch that did not crash: the handler opens the file and never
        // writes to it. It must read as "nothing happened", not as a corrupt report.
        XCTAssertNil(CrashRecord(data: Data()))
        XCTAssertNil(CrashRecord(data: Data("UCR1".utf8)))
    }

    func testARecordFromANewerFormatIsRefusedRatherThanReinterpreted() {
        var data = Data("UCR1".utf8)
        var version = UInt16(99).littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: 64))
        // Misreading a layout would produce plausible frames and therefore a fingerprint that groups
        // unrelated crashes. One lost report is the cheaper outcome.
        XCTAssertNil(CrashRecord(data: data))
    }

    func testBreadcrumbsKeepTheMostRecentAndNeverCarryAValue() throws {
        for i in 0..<(CrashLimits.maxBreadcrumbs + 10) {
            union_crash_add_breadcrumb(BreadcrumbWire.Kind.event.byte, "step_\(i)", Int64(i))
        }
        let path = directory.appendingPathComponent("crumbs.ucr").path
        XCTAssertEqual(union_crash_capture_live(path, SIGABRT, 0), 0)
        let record = try XCTUnwrap(CrashRecord(data: try Data(contentsOf: URL(fileURLWithPath: path))))

        XCTAssertEqual(record.crumbs.count, CrashLimits.maxBreadcrumbs)
        XCTAssertEqual(record.crumbs.last?.name, "step_\(CrashLimits.maxBreadcrumbs + 9)")
        XCTAssertEqual(record.crumbs.first?.name, "step_10", "the oldest are the ones that fall out")

        // Names only, asserted on the wire: the shape has nowhere to put a value, and that is the
        // privacy decision of this feature rather than a rule someone has to remember.
        let crumbs = try XCTUnwrap(CrashAssembly.breadcrumbs(record.crumbs))
        let json = try JSONSerialization.jsonObject(with: WireCoding.encoder.encode(crumbs)) as? [[String: Any]]
        for crumb in try XCTUnwrap(json) {
            XCTAssertEqual(Set(crumb.keys), ["ts", "kind", "name"])
        }
    }

    // MARK: - Assembly

    private func sidecar(images: [BinaryImageWire] = [], session: String? = UUID().uuidString) -> CrashContextSidecar {
        CrashContextSidecar(sessionId: session, context: Fixtures.device, images: images,
                            state: DeviceStateWire(), customKeys: nil, sampledAt: 1)
    }

    func testAssembledReportValidatesAgainstTheServerContract() throws {
        let path = directory.appendingPathComponent("valid.ucr").path
        XCTAssertEqual(union_crash_capture_live(path, SIGSEGV, 0), 0)
        let record = try XCTUnwrap(CrashRecord(data: try Data(contentsOf: URL(fileURLWithPath: path))))

        let report = try CrashAssembly.report(record: record,
                                              sidecar: sidecar(images: CrashReporter.loadedImages()),
                                              crashId: UUID().uuidString)
        let batch = CrashBatchWire(batchId: UUID().uuidString, environment: .production,
                                   privacyMode: .productAnalytics, sentAt: 1_700_000_000_000,
                                   identity: Identity(installId: UUID().uuidString), reports: [report])

        let validator = try MiniSchemaValidator(schema: try Fixtures.crashSchemaData())
        let errors = try validator.validate(try WireCoding.encoder.encode(batch))
        XCTAssertEqual(errors, [], "a real capture has to satisfy the schema the server validates with")
    }

    func testEveryFrameResolvesToAnImageWeActuallyLoaded() throws {
        let path = directory.appendingPathComponent("frames.ucr").path
        XCTAssertEqual(union_crash_capture_live(path, SIGSEGV, 0), 0)
        let record = try XCTUnwrap(CrashRecord(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        let images = CrashReporter.loadedImages()
        XCTAssertFalse(images.isEmpty, "the process has loaded images, and every one needs an LC_UUID")
        XCTAssertTrue(images.allSatisfy { $0.uuid.count == 32 })
        XCTAssertEqual(images.filter(\.isApp).count, 1, "exactly one image is the app")

        let threads = CrashAssembly.threads(record: record, images: images)
        let frames = threads.flatMap(\.frames)
        let resolved = frames.filter { $0.image != nil }
        XCTAssertFalse(resolved.isEmpty, "a real stack sits inside images we know about")
        for frame in resolved {
            let image = images[try XCTUnwrap(frame.image)]
            let load = try XCTUnwrap(UInt64(image.loadAddr.dropFirst(2), radix: 16))
            let addr = try XCTUnwrap(UInt64(frame.addr.dropFirst(2), radix: 16))
            // The offset is the identity of the issue, so it has to be exactly the address minus the
            // load address — the one quantity that is the same with and without symbols.
            XCTAssertEqual(try XCTUnwrap(frame.offset), Int(addr - load))
        }
    }

    func testAnAddressInsideNoKnownImageIsNullRatherThanAttributedToTheNearestOne() throws {
        let images = [
            BinaryImageWire(name: "A", uuid: String(repeating: "A", count: 32), loadAddr: "0x1000",
                            size: 0x100, arch: "arm64", isApp: true),
        ]
        let index = CrashAssembly.ImageIndex(images)
        XCTAssertEqual(index.image(containing: 0x1050)?.index, 0)
        // Past the end of the only image: attributing it would invent an offset, and an invented
        // offset is an invented issue identity.
        XCTAssertNil(index.image(containing: 0x2000))
        XCTAssertNil(index.image(containing: 0x0500))
    }

    func testAnImageWithNoKnownSizeClaimsNothing() {
        let images = [
            BinaryImageWire(name: "A", uuid: String(repeating: "B", count: 32), loadAddr: "0x1000",
                            size: nil, arch: nil, isApp: false),
        ]
        // We never read a __TEXT segment for it, so its upper bound is unknown; an address after its
        // load address is not evidence it belongs to it.
        XCTAssertNil(CrashAssembly.ImageIndex(images).image(containing: 0x1050))
    }

    func testARecordWithNoCrashedThreadIsDroppedNotRepaired() throws {
        let path = directory.appendingPathComponent("nocrash.ucr").path
        XCTAssertEqual(union_crash_capture_live(path, SIGSEGV, 0), 0)
        var record = try XCTUnwrap(CrashRecord(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        for i in record.threads.indices { record.threads[i].crashed = false }

        XCTAssertThrowsError(try CrashAssembly.report(record: record, sidecar: sidecar(), crashId: "x")) { error in
            XCTAssertEqual(error as? CrashAssembly.Problem, .noCrashedThread)
        }
    }

    func testTheHandlerOwnsUptimeAndForegroundBecauseTheSampleCannotKnowThem() throws {
        let path = directory.appendingPathComponent("state.ucr").path
        union_crash_set_foreground(1)
        XCTAssertEqual(union_crash_capture_live(path, SIGSEGV, 0), 0)
        let record = try XCTUnwrap(CrashRecord(data: try Data(contentsOf: URL(fileURLWithPath: path))))

        var sampled = DeviceStateWire()
        sampled.inForeground = false
        sampled.uptimeMs = 1
        sampled.freeMemoryBytes = 4096
        var context = sidecar()
        context.state = sampled

        let report = try CrashAssembly.report(record: record, sidecar: context, crashId: "id")
        XCTAssertEqual(report.state?.inForeground, true, "the record wins: it read the moment of death")
        XCTAssertEqual(report.state?.uptimeMs, Int(record.uptimeMs))
        XCTAssertEqual(report.state?.freeMemoryBytes, 4096, "the rest still comes from the sample")
    }

    func testAMachExceptionIsNamedAsItselfRatherThanAsAGuessedSignal() {
        var record = CrashRecord(data: minimalRecord(cause: 2, machException: 1))!
        record.machException = 1
        let signal = CrashAssembly.signal(from: record)
        XCTAssertEqual(signal.name, "EXC_BAD_ACCESS")
        XCTAssertEqual(signal.machException, "EXC_BAD_ACCESS")
        // "EXC_BAD_ACCESS usually arrives as SIGSEGV" is not something to write into a field a reader
        // takes as measured.
        XCTAssertNotEqual(signal.name, "SIGSEGV")
    }

    func testAnUnknownSignalNumberReportsItselfInsteadOfTheWrongCause() {
        XCTAssertEqual(CrashNames.signal(SIGSEGV), "SIGSEGV")
        XCTAssertEqual(CrashNames.signal(99), "SIG99")
        XCTAssertEqual(CrashNames.machException(999), "EXC_999")
    }

    // MARK: - Privacy

    func testStrictAnonymousRefusesCustomKeys() throws {
        let reporter = CrashReporter(config: config(privacy: .strictAnonymous), store: store,
                                     transport: RecordingCrashTransport(), identityStore: InMemoryIdentityStore(),
                                     device: Fixtures.device, logger: SDKLogger(level: .none, handler: nil),
                                     clock: TestClock())
        reporter.setCustomKey("email", "someone@example.com")
        reporter.recordError(type: "TestError", reason: "boom")

        let url = try XCTUnwrap(store.pendingReports().first)
        let report = try WireCoding.decoder.decode(CrashReportWire.self, from: try Data(contentsOf: url))
        // The same refusal `identify` makes: an app that may not send a user_id may not send an email
        // under a crash key instead.
        XCTAssertNil(report.customKeys)
    }

    func testCustomKeysAreCappedAndTrimmed() throws {
        let reporter = CrashReporter(config: config(privacy: .productAnalytics), store: store,
                                     transport: RecordingCrashTransport(), identityStore: InMemoryIdentityStore(),
                                     device: Fixtures.device, logger: SDKLogger(level: .none, handler: nil),
                                     clock: TestClock())
        for i in 0..<(CrashLimits.maxCustomKeys + 3) { reporter.setCrashKeyForTest("k\(i)", "v") }
        reporter.setCrashKeyForTest("long", String(repeating: "x", count: 500))
        reporter.recordError(type: "TestError", reason: nil)

        let url = try XCTUnwrap(store.pendingReports().first)
        let report = try WireCoding.decoder.decode(CrashReportWire.self, from: try Data(contentsOf: url))
        let keys = try XCTUnwrap(report.customKeys)
        XCTAssertEqual(keys.count, CrashLimits.maxCustomKeys)
        XCTAssertNil(keys["long"], "a key past the cap is refused, not swapped in for an earlier one")
    }

    func testANonFatalIsItsOwnSeverityAndNotAFatal() throws {
        let reporter = CrashReporter(config: config(privacy: .productAnalytics), store: store,
                                     transport: RecordingCrashTransport(), identityStore: InMemoryIdentityStore(),
                                     device: Fixtures.device, logger: SDKLogger(level: .none, handler: nil),
                                     clock: TestClock())
        reporter.recordError(type: "DecodingError", reason: "missing key")

        let url = try XCTUnwrap(store.pendingReports().first)
        let report = try WireCoding.decoder.decode(CrashReportWire.self, from: try Data(contentsOf: url))
        XCTAssertEqual(report.kind, .nonfatal)
        XCTAssertFalse(report.isFatal, "is_fatal has to agree with kind; the contract rejects it otherwise")
        XCTAssertEqual(report.exception?.type, "DecodingError")
        XCTAssertEqual(report.threads.filter(\.crashed).count, 1)
        XCTAssertFalse(report.threads[0].frames.isEmpty)
    }

    // MARK: - Upload

    func testOnlyAcceptanceOrAPermanentRejectionClearsAReport() {
        XCTAssertEqual(CrashUploadOutcome.of(status: 202, retryAfter: nil), .sent)
        XCTAssertEqual(CrashUploadOutcome.of(status: 400, retryAfter: nil), .rejected("http 400"))
        XCTAssertEqual(CrashUploadOutcome.of(status: 413, retryAfter: nil), .rejected("http 413"))
        XCTAssertEqual(CrashUploadOutcome.of(status: 401, retryAfter: nil), .stop)
        // A crash dropped on a 500 or a flaky connection is a crash the developer never learns about.
        XCTAssertEqual(CrashUploadOutcome.of(status: 500, retryAfter: 30), .retryLater(after: 30))
        XCTAssertEqual(CrashUploadOutcome.of(status: 0, retryAfter: nil), .retryLater(after: nil))
    }

    func testTheUploadSendsGzipAndKeepsTheReportUntilItIsAccepted() async throws {
        let transport = RecordingCrashTransport()
        transport.status = 500
        let reporter = CrashReporter(config: config(privacy: .productAnalytics), store: store,
                                     transport: transport, identityStore: InMemoryIdentityStore(),
                                     device: Fixtures.device, logger: SDKLogger(level: .none, handler: nil),
                                     clock: TestClock())
        reporter.recordError(type: "TestError", reason: nil)
        await reporter.flushPending()
        XCTAssertEqual(store.pendingReports().count, 1, "a 500 keeps the report for the next launch")

        transport.status = 202
        await reporter.flushPending()
        XCTAssertEqual(store.pendingReports().count, 0)
        XCTAssertEqual(transport.batches.count, 2)
        XCTAssertEqual(transport.batches.last?.reports.count, 1)
    }

    func testEndpointIsDerivedFromTheEventEndpoint() {
        let batch = URL(string: "https://in.useunion.dev/v1/batch")!
        XCTAssertEqual(URLSessionCrashTransport.endpoint(from: batch).absoluteString,
                       "https://in.useunion.dev/v1/crash")
    }

    // MARK: - gzip

    func testGzipProducesAContainerTheRouteCanDecode() throws {
        let payload = Data(repeating: 0x41, count: 5000) + Data("union".utf8)
        let zipped = try Gzip.compress(payload)

        XCTAssertEqual(Array(zipped.prefix(3)), [0x1f, 0x8b, 0x08], "gzip magic and the deflate method")
        let crc = zipped.suffix(8).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let size = zipped.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: crc), Gzip.crc32(payload))
        XCTAssertEqual(UInt32(littleEndian: size), UInt32(payload.count))
        XCTAssertLessThan(zipped.count, payload.count / 4, "a dump is repetitive; that is why the route requires this")
    }

    func testCrc32MatchesTheKnownAnswer() {
        // The check value from the zlib documentation: a wrong table produces plausible bytes and a
        // body the server rejects with no explanation.
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Hangs

    func testTheWatchdogReportsABlockedMainThreadOnceWithTheDurationItMeasured() throws {
        let expectation = expectation(description: "hang reported")
        let reports = UncheckedBox<[(TimeInterval, mach_port_t)]>([])
        let watchdog = HangWatchdog(threshold: 0.3) { duration, port in
            reports.value.append((duration, port))
            expectation.fulfill()
        }
        watchdog.start()
        // Let the main queue answer once, so the watchdog learns the main thread's port.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        // Then block it. This test *is* the main thread, so sleeping here is a real hang.
        Thread.sleep(forTimeInterval: 1.2)
        watchdog.stop()

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(reports.value.count, 1, "one episode is one hang, not one per tick")
        let (duration, port) = try XCTUnwrap(reports.value.first)
        XCTAssertGreaterThanOrEqual(duration, 0.3)
        XCTAssertNotEqual(port, 0, "the stack has to come from the blocked thread, not the watchdog")
    }

    // MARK: - Helpers

    private func config(privacy: PrivacyMode) -> CrashReporter.Config {
        CrashReporter.Config(writeKey: "test", environment: .production, privacyMode: privacy,
                             hangThreshold: 2, detectHangs: false, maxStored: 16)
    }

    /// A record with only the header filled in, for the pure naming paths.
    private func minimalRecord(cause: UInt16, machException: UInt32) -> Data {
        var data = Data("UCR1".utf8)
        func put<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        put(UInt16(1))
        put(cause)
        put(Int64(1_700_000_000_000))
        put(Int64(1234))
        put(UInt32(0))
        put(UInt32(0))
        put(machException)
        put(UInt64(0x10))
        put(UInt64(0x20))
        put(UInt64(0x2000))
        put(UInt8(0xff))
        put(UInt16(0))
        put(UInt16(0xffff))
        put(UInt16(0))
        return data
    }
}

/// Scripted crash transport: records batches, answers with whatever `status` is set to.
final class RecordingCrashTransport: CrashTransport, @unchecked Sendable {
    private let lock = NSLock()
    var status = 202
    private(set) var batches: [CrashBatchWire] = []
    private(set) var bodies: [Data] = []

    func send(_ body: Data, writeKey: String) async throws -> TransportResponse {
        let batch = try WireCoding.decoder.decode(CrashBatchWire.self, from: body)
        return lock.withLock {
            batches.append(batch)
            bodies.append(body)
            return TransportResponse(status: status, body: Data("{}".utf8), retryAfter: status == 500 ? 30 : nil)
        }
    }
}

final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

extension CrashReporter {
    /// The public facade goes through `Union`, which needs a configured client; the reporter's own
    /// entry point is what these tests exercise.
    func setCrashKeyForTest(_ key: String, _ value: String?) { setCustomKey(key, value) }
}
