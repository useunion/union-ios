import Foundation

enum Batcher {
    /// Takes the longest prefix of `queue` that fits the contract: ≤100 events and ≤256 KB when serialized
    /// (envelope reserve ~1 KB). Always returns at least one event when the queue is non-empty, so a single
    /// oversized event is sent alone and rejected by the server rather than blocking the queue forever.
    static func nextBatch(from queue: [Event], maxEvents: Int = Limits.batchMaxEvents, maxBytes: Int = Limits.batchMaxBytes) -> [Event] {
        var out: [Event] = []
        var bytes = 1024
        for e in queue.prefix(maxEvents) {
            let size = (try? WireCoding.encoder.encode(e).count) ?? 0
            if !out.isEmpty && bytes + size + 1 > maxBytes { break }
            out.append(e)
            bytes += size + 1
        }
        return out
    }
}
