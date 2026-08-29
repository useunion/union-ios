import Foundation

/// Wires real dependencies together. One instance per `configure`.
final class Client: Sendable {
    let pipeline: EventPipeline
    let logger: SDKLogger
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
        logger.log(.info, "configured · env=\(environment.rawValue) · privacy=\(privacyMode.rawValue) · sdk=\(SDKInfo.version)")
        let p = pipeline
        Task { await p.start(hadPersistentIdentity: hadIdentity) }
        #if canImport(UIKit) && !os(watchOS)
        let auto = options.automaticScreenTracking
        Task { @MainActor in
            self.lifecycle = AppLifecycleObserver(pipeline: p)
            if auto { AutomaticScreenTracking.install() }
        }
        #endif
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
