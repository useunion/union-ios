import Foundation

/// Durable queue of not-yet-acknowledged events.
protocol EventStore: Sendable {
    func load() throws -> [Event]
    func append(_ event: Event) throws
    func replaceAll(_ events: [Event]) throws
}

final class InMemoryEventStore: EventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []
    func load() throws -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
    func append(_ event: Event) throws { lock.lock(); events.append(event); lock.unlock() }
    func replaceAll(_ events: [Event]) throws { lock.lock(); self.events = events; lock.unlock() }
}

/// NDJSON append log in Application Support/AppVisitors/<keyHash>/queue.ndjson, excluded from backups.
/// Append is O(1); the file is rewritten (compacted) only after a batch is acknowledged or evicted.
final class FileEventStore: EventStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(directoryName: String) throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("AppVisitors", isDirectory: true).appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        url = dir.appendingPathComponent("queue.ndjson")
    }

    func load() throws -> [Event] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? WireCoding.decoder.decode(Event.self, from: Data($0)) }
    }

    func append(_ event: Event) throws {
        lock.lock(); defer { lock.unlock() }
        var line = try WireCoding.encoder.encode(event)
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    func replaceAll(_ events: [Event]) throws {
        lock.lock(); defer { lock.unlock() }
        var data = Data()
        for e in events {
            data.append(try WireCoding.encoder.encode(e))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }
}

/// UserDefaults is thread-safe but not marked Sendable; the wrapper is the only holder of the reference.
final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(suite: String = "com.appvisitors.sdk") { defaults = UserDefaults(suiteName: suite) ?? .standard }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var dict: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return dict[key] }
    func set(_ value: String?, forKey key: String) { lock.lock(); dict[key] = value; lock.unlock() }
}
