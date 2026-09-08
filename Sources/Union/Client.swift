import Foundation

/// Wires real dependencies together. One instance per `configure`.
final class Client: Sendable {
    let pipeline: EventPipeline
    let logger: SDKLogger
    /// Held so `Union.installId` can read the id without hopping onto the pipeline
    /// actor: the facade is synchronous everywhere else, and an `async` getter here
    /// would be the only call a caller has to await.
    let identityStore: IdentityStore
    /// `nil` when `Options.crashReporting` is off — nothing is installed then, not even the directory.
    let crash: CrashReporter?
    #if canImport(UIKit) && !os(watchOS)
    @MainActor private var lifecycle: AppLifecycleObserver?
    #endif

    init(writeKey: String, privacyMode: PrivacyMode, options: Options) {
        logger = SDKLogger(level: options.logLevel, handler: options.logHandler)
        let device = DeviceContextProvider.current()
        let environment = options.environment ?? EnvironmentDetector.detect()
        // Deterministic: Swift's `hashValue` is seeded per process, which would give every launch a new queue directory.
        let keyHash = Client.stableHash(writeKey)
        let store: EventStore = (try? FileEventStore(directoryName: keyHash)) ?? InMemoryEventStore()
        let identityStore: IdentityStore
        #if canImport(Security)
        identityStore = privacyMode == .strictAnonymous ? NoopIdentityStore() : KeychainIdentityStore()
        #else
        identityStore = privacyMode == .strictAnonymous ? NoopIdentityStore() : InMemoryIdentityStore()
        #endif
        let hadIdentity = identityStore.load().installId != nil
        self.identityStore = identityStore
        pipeline = EventPipeline(
            config: PipelineConfig(writeKey: writeKey, environment: environment, privacyMode: privacyMode, flushAt: options.flushAt, flushInterval: options.flushInterval, maxQueuedEvents: options.maxQueuedEvents),
            store: store,
            transport: URLSessionTransport(endpoint: options.endpoint),
            identityStore: identityStore,
            kv: UserDefaultsStore(),
            clock: SystemClock(),
            logger: logger,
            device: device
        )
        /*
         * Crash reporting is installed before the first event is pushed, because the window it cannot
         * cover is the window before it exists — and a crash during launch is the crash a developer
         * most wants and least often gets.
         */
        let reporter = options.crashReporting
            ? Client.makeCrashReporter(writeKey: writeKey, keyHash: keyHash, environment: environment,
                                       privacyMode: privacyMode, options: options, device: device,
                                       identityStore: identityStore, logger: logger)
            : nil
        crash = reporter
        logger.log(.info, "configured · env=\(environment.rawValue) · privacy=\(privacyMode.rawValue) · sdk=\(SDKInfo.version) · crashes=\(options.crashReporting ? "on" : "off")")
        let p = pipeline
        if let reporter {
            Task { await p.attach(crash: reporter) }
            reporter.start(sessionId: nil)
        }
        Task { await p.start(hadPersistentIdentity: hadIdentity) }
        #if canImport(UIKit) && !os(watchOS)
        let auto = options.automaticScreenTracking
        Task { @MainActor in
            self.lifecycle = AppLifecycleObserver(pipeline: p, crash: reporter)
            if auto { AutomaticScreenTracking.install() }
        }
        #endif
    }

    private static func makeCrashReporter(writeKey: String,
                                          keyHash: String,
                                          environment: Environment,
                                          privacyMode: PrivacyMode,
                                          options: Options,
                                          device: DeviceContext,
                                          identityStore: IdentityStore,
                                          logger: SDKLogger) -> CrashReporter? {
        guard let store = try? CrashStore.standard(directoryName: keyHash) else {
            // No directory means no descriptor for the handler to write to, so there is nothing to
            // install. Said out loud rather than left as a reporter that silently reports nothing.
            logger.log(.warning, "crash: could not create the crash directory — crash reporting is off")
            return nil
        }
        let endpoint = options.crashEndpoint ?? URLSessionCrashTransport.endpoint(from: options.endpoint)
        return CrashReporter(
            config: CrashReporter.Config(writeKey: writeKey, environment: environment,
                                         privacyMode: privacyMode, hangThreshold: options.hangThreshold,
                                         detectHangs: options.hangDetection,
                                         maxStored: options.maxStoredCrashReports),
            store: store,
            transport: URLSessionCrashTransport(endpoint: endpoint),
            identityStore: identityStore,
            device: device,
            logger: logger,
            clock: SystemClock()
        )
    }

    /// FNV-1a 64-bit, base-36. Stable across launches and OS versions; only used to name the on-disk queue directory.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
