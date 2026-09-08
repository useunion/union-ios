import Foundation
import UnionCrashCore
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Crash reporting, as the SDK sees it.
///
/// The whole design follows from one fact: **the process that died does not send the report.** The C
/// core writes a record to a descriptor it opened in advance; this type reads whatever is on disk on
/// the *next* launch, turns it into the wire contract and uploads it. Everything here therefore runs
/// in a healthy process, which is why it is allowed to allocate, take locks and use Foundation.
///
/// Three things it must not do, and each has a branch below: send a report it cannot attribute
/// (no sidecar), delete a report the server has not accepted (only 2xx and a permanent rejection
/// clear the file), or hold a device state and call it the state at the instant of death.
final class CrashReporter: @unchecked Sendable {
    struct Config: Sendable {
        var writeKey: String
        var environment: Environment
        var privacyMode: PrivacyMode
        /// How long the main thread must be unresponsive before it counts as a hang.
        var hangThreshold: TimeInterval
        var detectHangs: Bool
        /// Ceiling on stored reports, so a launch-crash loop offline cannot fill the disk.
        var maxStored: Int
    }

    private let config: Config
    private let store: CrashStore
    private let transport: CrashTransport
    private let identityStore: IdentityStore
    private let device: DeviceContext
    private let logger: SDKLogger
    private let clock: Clock

    private let lock = NSLock()
    /// The id of *this* launch's record: the file the handler owns and nobody may upload yet.
    private let currentId = UUID().uuidString
    private var sessionId: String?
    private var customKeys: [String: String] = [:]
    private var state = DeviceStateWire()
    private var images: [BinaryImageWire] = []
    private var lastSampleAt: Date = .distantPast
    private var installed = false
    private var watchdog: HangWatchdog?

    /// Re-sampling the device on every breadcrumb would put two syscalls and a UIKit read in front of
    /// every screen change; a few seconds of staleness in a field the panel already labels as a
    /// sample is the cheaper mistake.
    private static let sampleInterval: TimeInterval = 5

    init(config: Config,
         store: CrashStore,
         transport: CrashTransport,
         identityStore: IdentityStore,
         device: DeviceContext,
         logger: SDKLogger,
         clock: Clock) {
        self.config = config
        self.store = store
        self.transport = transport
        self.identityStore = identityStore
        self.device = device
        self.logger = logger
        self.clock = clock
    }

    // MARK: - Lifecycle

    /**
     * Installs the handlers, then sends what previous launches left behind.
     *
     * The order matters: the sidecar is written **before** the handlers are installed, because a
     * crash in the microsecond after installation would otherwise produce a record with nothing to
     * explain it. And the upload runs after, so a crash during the upload of an older crash still
     * lands as its own record.
     */
    func start(sessionId: String?) {
        lock.lock()
        guard !installed else { lock.unlock(); return }
        installed = true
        self.sessionId = sessionId
        images = CrashReporter.loadedImages()
        state = DeviceStateSampler.sample()
        lastSampleAt = clock.now
        lock.unlock()

        do {
            try store.writeImages(images, id: currentId)
            try persistContext()
        } catch {
            logger.log(.warning, "crash: could not write the crash sidecar (\(error)) — not installing")
            return
        }

        let path = store.recordURL(id: currentId).path
        if union_crash_install(path) != 0 {
            logger.log(.warning, "crash: could not open \(path) — handlers not installed")
            return
        }
        installUncaughtExceptionHandler()
        if config.detectHangs { startWatchdog() }
        logger.log(.info, "crash: handlers installed · record=\(currentId)")

        store.trim(max: config.maxStored)
        Task { await self.flushPending() }
    }

    /// Opt-out: stop collecting and take what is already on disk.
    func wipe() {
        stop()
        let files = (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)) ?? []
        for url in files { try? FileManager.default.removeItem(at: url) }
    }

    func stop() {
        union_crash_uninstall()
        CrashExceptionBridge.uninstall()
        lock.lock()
        watchdog?.stop()
        watchdog = nil
        installed = false
        lock.unlock()
    }

    // MARK: - Live context

    func breadcrumb(_ kind: BreadcrumbWire.Kind, _ name: String) {
        let trimmed = String(name.prefix(CrashLimits.breadcrumbNameMaxLength))
        union_crash_add_breadcrumb(kind.byte, trimmed, Int64(clock.now.timeIntervalSince1970 * 1000))
        resampleIfStale()
    }

    func setForeground(_ foreground: Bool) {
        union_crash_set_foreground(foreground ? 1 : 0)
        lock.lock()
        state = DeviceStateSampler.sample()
        lastSampleAt = clock.now
        lock.unlock()
        try? persistContext()
    }

    func setSessionId(_ id: String?) {
        lock.lock()
        sessionId = id
        lock.unlock()
        try? persistContext()
    }

    /**
     * The app's own label on a crash — Crashlytics' custom keys.
     *
     * Refused in `strictAnonymous`, exactly as `identify` is: an app that may not send a `user_id`
     * must not be able to send `{"email": …}` under a crash key instead. The contract rejects such a
     * batch too, so this is the second of two locks on the same door.
     */
    func setCustomKey(_ key: String, _ value: String?) {
        guard config.privacyMode != .strictAnonymous else {
            logger.log(.warning, "crash: custom keys are ignored in strict_anonymous")
            return
        }
        let trimmedKey = String(key.prefix(CrashLimits.customKeyMaxLength))
        guard !trimmedKey.isEmpty else { return }
        lock.lock()
        if let value {
            if customKeys[trimmedKey] == nil, customKeys.count >= CrashLimits.maxCustomKeys {
                lock.unlock()
                logger.log(.warning, "crash: at most \(CrashLimits.maxCustomKeys) custom keys; \(trimmedKey) ignored")
                return
            }
            customKeys[trimmedKey] = String(value.prefix(CrashLimits.customValueMaxLength))
        } else {
            customKeys.removeValue(forKey: trimmedKey)
        }
        lock.unlock()
        try? persistContext()
    }

    private func resampleIfStale() {
        lock.lock()
        let due = clock.now.timeIntervalSince(lastSampleAt) >= CrashReporter.sampleInterval
        if due {
            state = DeviceStateSampler.sample()
            lastSampleAt = clock.now
        }
        lock.unlock()
        if due { try? persistContext() }
    }

    private func persistContext() throws {
        lock.lock()
        let file = CrashContextFile(sessionId: sessionId,
                                    context: device,
                                    state: state,
                                    customKeys: customKeys.isEmpty ? nil : customKeys,
                                    sampledAt: Int64(lastSampleAt.timeIntervalSince1970 * 1000))
        lock.unlock()
        try store.writeContext(file, id: currentId)
    }

    // MARK: - Non-fatals

    /**
     * An error the app caught and wants counted, with the stack of whoever reported it.
     *
     * Written to disk like a fatal rather than sent inline, and for the same reason: the app may be
     * seconds from termination for an unrelated cause, and a report that only exists in memory is a
     * report that competes with the crash that is about to happen. `Thread.callStackReturnAddresses`
     * is safe here — this is ordinary code on a live thread, not a signal handler.
     */
    func recordError(type: String, reason: String?, kind: CrashKind = .nonfatal) {
        let addresses = Thread.callStackReturnAddresses.map { UInt64(truncating: $0) }
        record(type: type, reason: reason, kind: kind, frames: addresses, hangDurationMs: nil)
    }

    private func record(type: String,
                        reason: String?,
                        kind: CrashKind,
                        frames: [UInt64],
                        hangDurationMs: Int?) {
        lock.lock()
        let sidecar = CrashContextSidecar(sessionId: sessionId,
                                          context: device,
                                          images: images,
                                          state: state,
                                          customKeys: customKeys.isEmpty ? nil : customKeys,
                                          sampledAt: Int64(lastSampleAt.timeIntervalSince1970 * 1000))
        lock.unlock()

        var reportState = sidecar.state
        reportState.uptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)

        let index = CrashAssembly.ImageIndex(sidecar.images)
        let wireFrames = frames.prefix(CrashLimits.maxFramesPerThread).enumerated().map { position, addr in
            let found = index.image(containing: addr)
            return CrashFrameWire(n: position,
                                  addr: crashHex(addr),
                                  image: found?.index,
                                  offset: found.map { Int(addr - $0.loadAddr) },
                                  symbol: nil)
        }

        let report = CrashReportWire(
            crashId: UUID().uuidString,
            kind: kind,
            // Only `fatal` is fatal. A logged error and a frozen main thread are their own severities
            // and the server counts them in their own columns.
            isFatal: kind == .fatal,
            crashedAt: Int64(clock.now.timeIntervalSince1970 * 1000),
            sessionId: sidecar.sessionId,
            context: sidecar.context,
            state: reportState,
            signal: nil,
            exception: CrashExceptionWire(type: String(type.prefix(128)),
                                          reason: reason.map { String($0.prefix(CrashLimits.reasonMaxLength)) }),
            hangDurationMs: hangDurationMs,
            images: sidecar.images,
            threads: [CrashThreadWire(index: 0,
                                      name: Thread.isMainThread ? "com.apple.main-thread" : nil,
                                      crashed: true,
                                      frames: Array(wireFrames),
                                      framesTruncated: frames.count > CrashLimits.maxFramesPerThread)],
            breadcrumbs: nil,
            customKeys: sidecar.customKeys
        )
        do {
            try store.write(report: report)
            store.trim(max: config.maxStored)
        } catch {
            logger.log(.warning, "crash: could not store a \(kind.rawValue) report (\(error))")
        }
    }

    // MARK: - Hangs

    private func startWatchdog() {
        let dog = HangWatchdog(threshold: config.hangThreshold) { [weak self] duration, mainThread in
            self?.reportHang(duration: duration, mainThread: mainThread)
        }
        lock.lock()
        watchdog = dog
        lock.unlock()
        dog.start()
    }

    /**
     * A hang is reported from the watchdog while the app is still alive, so the stack has to be taken
     * off the **main** thread rather than off the thread that noticed. That is why the C core exposes
     * a live-capture entry point: it suspends the process, walks the blocked stack, and resumes.
     */
    private func reportHang(duration: TimeInterval, mainThread: mach_port_t) {
        let id = UUID().uuidString
        let path = store.directory.appendingPathComponent("\(id).hang").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard union_crash_capture_live(path, 0, mainThread) == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = CrashRecord(data: data)
        else {
            logger.log(.warning, "crash: could not capture the main thread for a hang")
            return
        }

        lock.lock()
        let sidecar = CrashContextSidecar(sessionId: sessionId, context: device, images: images,
                                          state: state, customKeys: customKeys.isEmpty ? nil : customKeys,
                                          sampledAt: Int64(lastSampleAt.timeIntervalSince1970 * 1000))
        lock.unlock()

        var reportState = sidecar.state
        reportState.uptimeMs = Int(record.uptimeMs)
        reportState.inForeground = record.foreground

        let report = CrashReportWire(
            crashId: id,
            kind: .hang,
            isFatal: false,
            crashedAt: record.crashedAt,
            sessionId: sidecar.sessionId,
            context: sidecar.context,
            state: reportState,
            signal: nil,
            // Named as what it is. A hang has no signal and no thrown error, and the contract needs a
            // signal or an exception to have something to group on.
            exception: CrashExceptionWire(type: "MainThreadHang", reason: nil),
            hangDurationMs: Int(duration * 1000),
            images: sidecar.images,
            threads: CrashAssembly.threads(record: record, images: sidecar.images),
            breadcrumbs: CrashAssembly.breadcrumbs(record.crumbs),
            customKeys: sidecar.customKeys
        )
        do {
            try store.write(report: report)
            store.trim(max: config.maxStored)
            logger.log(.info, "crash: main thread blocked for \(Int(duration * 1000))ms")
        } catch {
            logger.log(.warning, "crash: could not store a hang report (\(error))")
        }
    }

    // MARK: - Uncaught Obj-C exceptions

    /**
     * `NSSetUncaughtExceptionHandler` catches what the signal handlers see only as a bare `SIGABRT`
     * with no idea what was thrown. It runs before the process dies, on a healthy-enough thread, so
     * the report is built here in full and the previous handler is called afterwards — an app with
     * its own reporter installed keeps getting its own callback.
     */
    private func installUncaughtExceptionHandler() {
        #if canImport(ObjectiveC)
        CrashExceptionBridge.install { [weak self] name, reason, addresses in
            self?.record(type: name, reason: reason, kind: .fatal, frames: addresses, hangDurationMs: nil)
        }
        #endif
    }

    // MARK: - Upload

    /// Everything on disk from previous launches, oldest first.
    func flushPending() async {
        for pending in store.pending(excluding: currentId) {
            guard let data = try? Data(contentsOf: pending.record), let record = CrashRecord(data: data) else {
                logger.log(.warning, "crash: \(pending.id) is not a record this SDK can read — discarded")
                store.discard(id: pending.id)
                continue
            }
            guard let sidecar = store.loadSidecar(id: pending.id) else {
                logger.log(.warning, "crash: \(pending.id) has no context — discarded")
                store.discard(id: pending.id)
                continue
            }
            do {
                let report = try CrashAssembly.report(record: record, sidecar: sidecar, crashId: pending.id)
                switch await send([report]) {
                case .sent, .rejected:
                    store.discard(id: pending.id)
                // The report stays on disk. Deleting it here is the one mistake this whole path exists
                // to avoid: a crash dropped on a 500 or a flaky connection never happened as far as
                // the developer can ever tell.
                case .retryLater:
                    continue
                case .stop:
                    return
                }
            } catch CrashAssembly.Problem.noCrashedThread {
                // Documented in `CrashAssembly.Problem`: without a crashed thread there is nothing to
                // fingerprint, and picking one would put an issue on a stack nobody established.
                logger.log(.warning, "crash: \(pending.id) has no crashed thread — discarded")
                store.discard(id: pending.id)
            } catch {
                logger.log(.warning, "crash: \(pending.id) could not be assembled (\(error))")
                store.discard(id: pending.id)
            }
        }

        for url in store.pendingReports() {
            guard let data = try? Data(contentsOf: url),
                  let report = try? WireCoding.decoder.decode(CrashReportWire.self, from: data)
            else {
                store.discard(url: url)
                continue
            }
            switch await send([report]) {
            case .sent, .rejected: store.discard(url: url)
            case .retryLater: continue
            case .stop: return
            }
        }
    }

    private func send(_ reports: [CrashReportWire]) async -> CrashUploadOutcome {
        let identity = config.privacyMode == .strictAnonymous ? Identity.anonymous : identityStore.load()
        let batch = CrashBatchWire(batchId: UUID().uuidString,
                                   environment: config.environment,
                                   privacyMode: config.privacyMode,
                                   sentAt: Int64(clock.now.timeIntervalSince1970 * 1000),
                                   identity: identity,
                                   reports: Array(reports.prefix(CrashLimits.maxReportsPerBatch)))
        do {
            let body = try WireCoding.encoder.encode(batch)
            let response = try await transport.send(body, writeKey: config.writeKey)
            let outcome = CrashUploadOutcome.of(status: response.status, retryAfter: response.retryAfter)
            switch outcome {
            case .sent:
                logger.log(.debug, "crash: sent \(reports.count) report(s)")
            case .rejected(let why):
                // Kept out of the retry loop deliberately: this SDK version can never make this report
                // acceptable, so retrying it every launch would be a permanent, silent loop.
                logger.log(.warning, "crash: report rejected (\(why)) — discarded")
            case .stop:
                logger.log(.warning, "crash: upload refused (auth) — stopping for this launch")
            case .retryLater:
                logger.log(.debug, "crash: upload failed, keeping the report for the next launch")
            }
            return outcome
        } catch {
            // A network error keeps the file. A crash dropped on a flaky connection is a crash the
            // developer never learns about.
            logger.log(.debug, "crash: upload error (\(error)) — keeping the report")
            return .retryLater(after: nil)
        }
    }

    // MARK: - Images

    /// Snapshots dyld's image list through the C core, which reads `LC_UUID` and `__TEXT` for each.
    static func loadedImages() -> [BinaryImageWire] {
        var raw = [union_crash_image](repeating: union_crash_image(), count: CrashLimits.maxImages)
        let count = Int(union_crash_images(&raw, Int32(CrashLimits.maxImages)))
        return raw.prefix(max(0, count)).map { image in
            let name = withUnsafeBytes(of: image.name) { bytes -> String in
                let chars = bytes.prefix(while: { $0 != 0 })
                return String(decoding: chars, as: UTF8.self)
            }
            var uuid = ""
            if image.has_uuid == 1 {
                // Uppercase, no dashes: the exact spelling of `LC_UUID` in a dSYM, because a
                // difference in spelling looks identical to holding no dSYM at all.
                uuid = withUnsafeBytes(of: image.uuid) { bytes in
                    bytes.map { String(format: "%02X", $0) }.joined()
                }
            }
            return BinaryImageWire(name: String(name.suffix(255)),
                                   uuid: uuid,
                                   loadAddr: crashHex(image.load_addr),
                                   size: image.size == 0 ? nil : Int(image.size),
                                   arch: CrashReporter.arch,
                                   isApp: image.is_app == 1)
        }
        // An image with no `LC_UUID` is dropped by the caller below: without it there is no join key
        // to a dSYM, and an empty uuid fails the contract's pattern rather than travelling as blank.
        .filter { !$0.uuid.isEmpty }
    }

    static let arch: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()
}
