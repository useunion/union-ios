import Foundation

/**
 * One reader of the Keychain, and the reason it exists.
 *
 * Identity used to be loaded — and the install id minted — inside `EventPipeline.init`, which runs
 * inside `Client.init`, which apps call from `didFinishLaunching`. A Keychain read is IPC to
 * `securityd` and a mint is a read plus a write, so `Union.configure` paid for both on the main
 * thread at launch. `Union.installId` then went back to the Keychain on every access, on whatever
 * thread asked.
 *
 * So the load is neither eager nor lazy-per-caller: it happens **once, on whoever asks first**, and
 * the answer is cached. In practice that is the pipeline actor, off the main thread. An app that
 * reads `Union.installId` immediately after `configure` still gets an id — it pays the read on its
 * own thread, exactly as it did before — which is what keeps this a performance change and not a
 * contract change.
 */
final class IdentityCoordinator: @unchecked Sendable {
    private let store: IdentityStore
    private let privacyMode: PrivacyMode
    private let lock = NSLock()
    private var cached: Identity?
    private var hadPersistent = false

    init(store: IdentityStore, privacyMode: PrivacyMode) {
        self.store = store
        self.privacyMode = privacyMode
        // The one thing that is not deferred. "strict_anonymous stores no identity" is a promise
        // about what is on the device, not about what is read back, so anything an earlier mode left
        // goes now rather than on the first event. It costs nothing where it matters: `Client` pairs
        // that mode with `NoopIdentityStore`, whose `wipe` does nothing at all.
        if privacyMode == .strictAnonymous {
            store.wipe()
            cached = .anonymous
        }
    }

    /// Load-or-mint, once. `strictAnonymous` stores nothing and wipes anything an earlier mode left.
    @discardableResult
    func ensure(now: Date) -> Identity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var id = store.load()
        hadPersistent = id.installId != nil
        if id.installId == nil {
            id.installId = UUIDv7.generate(now: now)
            store.save(id)
        }
        cached = id
        return id
    }

    /// Whether an install id was already on the device before `ensure` ran — the `reinstall: true`
    /// signal. Meaningless before `ensure`, and every caller of it calls `ensure` first.
    var hadPersistentIdentity: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hadPersistent
    }

    func save(_ identity: Identity) {
        lock.lock()
        cached = identity
        lock.unlock()
        store.save(identity)
    }

    func wipe() {
        lock.lock()
        cached = .anonymous
        lock.unlock()
        store.wipe()
    }

    /// Drops the cache so the next `ensure` mints again — `optIn` after `optOut` is the one caller.
    func forget() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
