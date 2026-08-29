import Foundation

/// Mirrors `packages/contract/src/errors.ts`.
struct IngestAccepted: Decodable {
    var accepted: Int
    var rejected: Int
    var batchId: String
    enum CodingKeys: String, CodingKey { case accepted, rejected, batchId = "batch_id" }
}

struct ErrorResponse: Decodable {
    struct Detail: Decodable { var path: String; var message: String }
    var error: String
    var message: String
    var details: [Detail]?

    /// Indices of rejected events from Zod paths like `events.3.properties.foo`.
    var rejectedEventIndices: Set<Int> {
        Set((details ?? []).compactMap { d in
            let parts = d.path.split(separator: ".")
            guard parts.count >= 2, parts[0] == "events", let i = Int(parts[1]) else { return nil }
            return i
        })
    }

    /// Details that are not about a specific event (envelope/identity/environment) mean the whole batch is wrong.
    var hasEnvelopeProblem: Bool {
        (details ?? []).contains { !$0.path.hasPrefix("events.") }
    }
}

/// What the pipeline should do after a response.
enum Disposition: Equatable {
    /// Batch acknowledged (server may have filtered `rejected` events via kill switch).
    case accepted(rejected: Int)
    /// Drop these events (by index within the sent batch); keep and immediately retry the rest.
    case dropEvents(Set<Int>)
    /// Drop the entire batch (config bug: env mismatch, privacy violation, malformed envelope, unsupported contract).
    case dropBatch(reason: String)
    /// Batch too large: send half.
    case split
    /// Keep the batch, wait, then retry.
    case pause(TimeInterval, reason: String)
    /// Invalid write key: stop for the process lifetime.
    case stop(reason: String)
    /// Transient: exponential backoff.
    case retryLater

    static func from(_ r: TransportResponse) -> Disposition {
        switch r.status {
        case 202:
            let ok = try? WireCoding.decoder.decode(IngestAccepted.self, from: r.body)
            return .accepted(rejected: ok?.rejected ?? 0)
        case 400:
            guard let err = try? WireCoding.decoder.decode(ErrorResponse.self, from: r.body) else { return .dropBatch(reason: "400") }
            if err.error == "privacy_violation" { return .dropBatch(reason: err.message) }
            let idx = err.rejectedEventIndices
            if !idx.isEmpty && !err.hasEnvelopeProblem { return .dropEvents(idx) }
            return .dropBatch(reason: "\(err.error): \(err.message)")
        case 401: return .stop(reason: "invalid write key")
        case 403: return .pause(3600, reason: "project disabled")
        case 413: return .split
        case 429: return .pause(r.retryAfter ?? 300, reason: "rate limited / quota exceeded")
        case 500...599, 0: return .retryLater
        default: return .retryLater
        }
    }
}

/// Exponential backoff with full jitter: 2s, 4s, 8s … capped at 5 min.
enum Backoff {
    static func delay(attempt: Int) -> TimeInterval {
        let base = min(300, 2 * pow(2, Double(max(0, attempt))))
        return Double.random(in: 0.5...1.0) * base
    }
}
