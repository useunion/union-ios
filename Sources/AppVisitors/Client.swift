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
        let keyHash = String(writeKey.hashValue.magnitude, radix: 36)
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
}
