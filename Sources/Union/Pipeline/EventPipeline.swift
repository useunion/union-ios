import Foundation

struct PipelineConfig: Sendable {
    var writeKey: String
    var environment: Environment
    var privacyMode: PrivacyMode
    var flushAt: Int
    var flushInterval: TimeInterval
    var maxQueuedEvents: Int
}

/// Owns the queue, session state, identity and network. Every public SDK call ends up here.
/// Single actor → no locks, ordered enqueue, one in-flight flush.
actor EventPipeline {
    private let config: PipelineConfig
    private let store: EventStore
    private let transport: Transport
    private let identityStore: IdentityStore
    private let clock: Clock
    private let logger: SDKLogger
    private let device: DeviceContext

    private var queue: [Event] = []
    private var session: SessionManager
    private var identity: Identity
    private var stopped = false
    private var pausedUntil: Date?
    private var attempt = 0
    private var flushing = false
    private var timer: Task<Void, Never>?
    private(set) var optedOut = false

    init(config: PipelineConfig, store: EventStore, transport: Transport, identityStore: IdentityStore, kv: KeyValueStore, clock: Clock, logger: SDKLogger, device: DeviceContext) {
        self.config = config
        self.store = store
        self.transport = transport
        self.identityStore = identityStore
        self.clock = clock
        self.logger = logger
        self.device = device
        self.session = SessionManager(clock: clock, store: kv)
        self.optedOut = kv.string(forKey: "opt_out") == "1"
        self.kv = kv
        var id = identityStore.load()
        if config.privacyMode == .strictAnonymous {
            identityStore.wipe()
            id = .anonymous
        } else if id.installId == nil {
            id.installId = UUIDv7.generate(now: clock.now)
            identityStore.save(id)
        }
        self.identity = id
        self.queue = (try? store.load()) ?? []
    }

    private let kv: KeyValueStore

    // MARK: - Lifecycle entry points (called by Client / AppLifecycleObserver)

    /// Cold start: install/update detection, then session start.
    func start(hadPersistentIdentity: Bool) {
        guard !optedOut else { return }
        let outcome = InstallState.evaluate(store: kv, device: device, hadPersistentIdentity: hadPersistentIdentity)
        let t = session.touch()
        let sid: String
        var pre: [Event] = []
        switch t {
        case .continued(let id): sid = id
        case .rotated(let ended, let started):
            sid = started.sessionId
            if let ended { pre.append(system(.sessionEnd, sessionId: ended.sessionId, at: ended.lastActivityAt)) }
        }
        switch outcome {
        case .firstOpen(let reinstall):
            pre.append(system(.firstOpen, sessionId: sid))
            pre.append(system(.appInstall, sessionId: sid, properties: ["reinstall": .bool(reinstall)]))
        case .updated(let pv, let pb):
            pre.append(system(.appUpdate, sessionId: sid, properties: ["previous_version": .string(pv), "previous_build": .string(pb)]))
        case .unchanged: break
        }
        if case .rotated(_, let started) = t { pre.append(system(.sessionStart, sessionId: started.sessionId, at: started.startedAt)) }
        for e in pre { push(e) }
        startTimer()
        scheduleFlushIfNeeded()
    }

    func didEnterBackground() async {
        guard !optedOut else { return }
        if case .continued(let sid) = session.touch() { push(system(.background, sessionId: sid)) }
        timer?.cancel(); timer = nil
        await flush()
    }

    func willEnterForeground() {
        guard !optedOut else { return }
        switch session.touch() {
        case .continued(let sid): push(system(.foreground, sessionId: sid))
        case .rotated(let ended, let started):
            if let ended { push(system(.sessionEnd, sessionId: ended.sessionId, at: ended.lastActivityAt)) }
            push(system(.sessionStart, sessionId: started.sessionId, at: started.startedAt))
        }
        startTimer()
        scheduleFlushIfNeeded()
    }

    func willTerminate() async {
        guard !optedOut, let cur = session.current else { return }
        push(system(.sessionEnd, sessionId: cur.sessionId))
        await flush()
    }

    // MARK: - Public operations

    func track(name: String, properties: [String: PropertyValue], role: FeatureRole?, screen: String?) {
        guard !optedOut, !stopped else { return }
        do {
            try Validation.validateCustomName(name)
            try Validation.validate(properties: properties)
            try Validation.validate(screen: screen)
        } catch {
            logger.log(.warning, "dropped event \"\(name)\": \(error)")
            return
        }
        let sid = liveSessionId()
        push(Event(eventId: UUIDv7.generate(now: clock.now), sessionId: sid, name: name, timestamp: nowMs(), screen: screen, properties: properties.isEmpty ? nil : properties, role: role))
        scheduleFlushIfNeeded()
    }

    func screen(name: String, properties: [String: PropertyValue]) {
        guard !optedOut, !stopped else { return }
        do {
            try Validation.validate(screen: name)
            try Validation.validate(properties: properties)
        } catch {
            logger.log(.warning, "dropped screen \"\(name)\": \(error)")
            return
        }
        push(system(.screenView, sessionId: liveSessionId(), screen: name, properties: properties.isEmpty ? nil : properties))
        scheduleFlushIfNeeded()
    }

    func deepLink(_ url: URL) {
        guard !optedOut, !stopped else { return }
        var props: [String: PropertyValue] = [:]
        if let s = url.scheme { props["url_scheme"] = .string(String(s.prefix(Limits.propertyStringMaxLength))) }
        if let h = url.host { props["host"] = .string(String(h.prefix(Limits.propertyStringMaxLength))) }
        props["path"] = .string(String(url.path.prefix(Limits.propertyStringMaxLength)))
        push(system(.deepLink, sessionId: liveSessionId(), properties: props))
        scheduleFlushIfNeeded()
    }

    func identify(userId: String) {
        guard !optedOut else { return }
        guard config.privacyMode == .productAnalytics else {
            logger.log(.warning, "identify() ignored: project is strict_anonymous")
            return
        }
        do { try Validation.validate(userId: userId) } catch {
            logger.log(.warning, "identify() ignored: \(error)")
            return
        }
        identity.userId = userId
        identityStore.save(identity)
    }

    /// Logout: forget user id and rotate the session; the install id stays (it identifies the device, not the person).
    func reset() {
        identity.userId = nil
        identityStore.save(identity)
        if case .rotated(let ended, let started) = session.rotate() {
            if let ended { push(system(.sessionEnd, sessionId: ended.sessionId)) }
            push(system(.sessionStart, sessionId: started.sessionId, at: started.startedAt))
        }
    }

    /// Stops collection, wipes queue, identity and session state, persists the flag.
    func optOut() {
        optedOut = true
        kv.set("1", forKey: "opt_out")
        queue.removeAll()
        try? store.replaceAll([])
        identityStore.wipe()
        identity = .anonymous
        session.clear()
        timer?.cancel(); timer = nil
        logger.log(.info, "opted out: collection stopped, local data wiped")
    }

    func optIn() {
        guard optedOut else { return }
        optedOut = false
        kv.set(nil, forKey: "opt_out")
        var id = identityStore.load()
        if config.privacyMode == .productAnalytics, id.installId == nil {
            id.installId = UUIDv7.generate(now: clock.now)
            identityStore.save(id)
        }
        identity = id
        start(hadPersistentIdentity: false)
    }

    // MARK: - Flush

    func flush() async {
        guard !flushing, !stopped, !optedOut else { return }
        if let until = pausedUntil, until > clock.now { return }
        flushing = true
        defer { flushing = false }
        var maxEvents = Limits.batchMaxEvents
        while !queue.isEmpty {
            let batch = Batcher.nextBatch(from: queue, maxEvents: maxEvents)
            let envelope = EventBatch(batchId: UUIDv7.generate(now: clock.now), environment: config.environment, privacyMode: config.privacyMode, sentAt: nowMs(), device: device, identity: identity, events: batch)
            guard let body = try? WireCoding.encoder.encode(envelope) else { return }
            let response: TransportResponse
            do { response = try await transport.send(body, writeKey: config.writeKey) } catch {
                logger.log(.debug, "network error: \(error.localizedDescription)")
                backoff(); return
            }
            switch Disposition.from(response) {
            case .accepted(let rejected):
                attempt = 0
                maxEvents = Limits.batchMaxEvents
                if rejected > 0 { logger.log(.info, "\(rejected) event(s) filtered server-side (kill switch)") }
                logger.log(.info, "sent \(batch.count) event(s): \(batch.map(\.name).joined(separator: ", "))")
                removeFromQueue(batch)
            case .dropEvents(let indices):
                let bad = indices.compactMap { batch.indices.contains($0) ? batch[$0] : nil }
                logger.log(.error, "server rejected \(bad.count) event(s): \(bad.map(\.name).joined(separator: ", "))")
                removeFromQueue(bad)
            case .dropBatch(let reason):
                logger.log(.error, "batch rejected (\(reason)); dropping \(batch.count) event(s). Check write key/environment/privacy mode.")
                removeFromQueue(batch)
            case .split:
                if maxEvents <= 1 { removeFromQueue(batch); logger.log(.error, "event too large; dropped") } else { maxEvents = max(1, maxEvents / 2) }
            case .pause(let seconds, let reason):
                pausedUntil = clock.now.addingTimeInterval(seconds)
                logger.log(.warning, "paused \(Int(seconds))s: \(reason)")
                return
            case .stop(let reason):
                stopped = true
                logger.log(.error, "stopped: \(reason)")
                return
            case .retryLater:
                backoff(); return
            }
        }
    }

    // MARK: - Internals

    private func liveSessionId() -> String {
        switch session.touch() {
        case .continued(let id): return id
        case .rotated(let ended, let started):
            if let ended { push(system(.sessionEnd, sessionId: ended.sessionId, at: ended.lastActivityAt)) }
            push(system(.sessionStart, sessionId: started.sessionId, at: started.startedAt))
            return started.sessionId
        }
    }

    private func system(_ kind: AutoEvent, sessionId: String, at: Int64? = nil, screen: String? = nil, properties: [String: PropertyValue]? = nil) -> Event {
        Event(eventId: UUIDv7.generate(now: clock.now), sessionId: sessionId, name: kind.rawValue, timestamp: at ?? nowMs(), screen: screen, properties: properties, role: nil)
    }

    private func nowMs() -> Int64 { Int64(clock.now.timeIntervalSince1970 * 1000) }

    private func push(_ e: Event) {
        queue.append(e)
        if queue.count > config.maxQueuedEvents {
            let drop = queue.count - config.maxQueuedEvents
            queue.removeFirst(drop)
            try? store.replaceAll(queue)
            logger.log(.warning, "queue full: evicted \(drop) oldest event(s)")
        } else {
            do { try store.append(e) } catch { logger.log(.debug, "persist failed: \(error.localizedDescription)") }
        }
    }

    private func removeFromQueue(_ events: [Event]) {
        let ids = Set(events.map(\.eventId))
        queue.removeAll { ids.contains($0.eventId) }
        try? store.replaceAll(queue)
    }

    private func backoff() {
        attempt += 1
        pausedUntil = clock.now.addingTimeInterval(Backoff.delay(attempt: attempt))
    }

    private func scheduleFlushIfNeeded() {
        guard queue.count >= config.flushAt else { return }
        Task { await self.flush() }
    }

    private func startTimer() {
        timer?.cancel()
        let interval = config.flushInterval
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await self.flush()
            }
        }
    }

    // Test hooks
    var queuedEvents: [Event] { queue }
    var currentSessionId: String? { session.current?.sessionId }
    var currentIdentity: Identity { identity }
    var isStopped: Bool { stopped }
    var isPaused: Bool { (pausedUntil ?? .distantPast) > clock.now }
}
