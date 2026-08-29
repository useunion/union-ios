import Foundation

protocol Clock: Sendable {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

/// Small key-value persistence for non-identifying SDK state (session snapshot, last version, opt-out).
protocol KeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

struct SessionSnapshot: Codable, Equatable, Sendable {
    var sessionId: String
    var startedAt: Int64
    var lastActivityAt: Int64
}

/// Session rules mirror the server (`SESSION_TIMEOUT_MS` in packages/domain): a session ends after 30 minutes
/// without activity. The SDK persists a snapshot so a kill-and-relaunch inside the window continues the session;
/// the server's alarm is authoritative if `$session_end` never arrives.
struct SessionManager: Sendable {
    static let timeout: TimeInterval = 30 * 60
    private static let key = "session"

    let clock: Clock
    let store: KeyValueStore
    private(set) var current: SessionSnapshot?

    init(clock: Clock, store: KeyValueStore) {
        self.clock = clock
        self.store = store
        if let raw = store.string(forKey: Self.key)?.data(using: .utf8),
           let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: raw) {
            current = snap
        }
    }

    enum Transition: Equatable {
        case continued(sessionId: String)
        /// `ended` is nil on a cold start with no prior snapshot.
        case rotated(ended: SessionSnapshot?, started: SessionSnapshot)
    }

    /// Ensures a live session for activity happening at `now`; rotates when the timeout elapsed.
    mutating func touch(now: Date? = nil) -> Transition {
        let t = now ?? clock.now
        let ms = Int64(t.timeIntervalSince1970 * 1000)
        if let cur = current, Double(ms - cur.lastActivityAt) / 1000 < Self.timeout {
            current = SessionSnapshot(sessionId: cur.sessionId, startedAt: cur.startedAt, lastActivityAt: ms)
            persist()
            return .continued(sessionId: cur.sessionId)
        }
        let ended = current
        let started = SessionSnapshot(sessionId: UUIDv7.generate(now: t), startedAt: ms, lastActivityAt: ms)
        current = started
        persist()
        return .rotated(ended: ended, started: started)
    }

    /// Forced rotation (reset()/identify change).
    mutating func rotate(now: Date? = nil) -> Transition {
        let t = now ?? clock.now
        let ms = Int64(t.timeIntervalSince1970 * 1000)
        let ended = current
        let started = SessionSnapshot(sessionId: UUIDv7.generate(now: t), startedAt: ms, lastActivityAt: ms)
        current = started
        persist()
        return .rotated(ended: ended, started: started)
    }

    mutating func clear() {
        current = nil
        store.set(nil, forKey: Self.key)
    }

    private func persist() {
        guard let cur = current, let data = try? JSONEncoder().encode(cur) else { return }
        store.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }
}
