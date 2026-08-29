import Foundation

/// Mirrors `environment` in the wire contract. A write key is bound to exactly one environment server-side.
public enum Environment: String, Codable, Sendable {
    case development, testflight, production
}

/// Mirrors `privacy_mode` in the wire contract (docs/Product/07-privacy-data.md).
/// `strictAnonymous` never persists an install id or user id; batches carry `identity: {}`.
public enum PrivacyMode: String, Codable, Sendable {
    case strictAnonymous = "strict_anonymous"
    case productAnalytics = "product_analytics"
}

/// Optional hint about the event's role inside a feature. The panel remains the source of truth.
public enum FeatureRole: String, Codable, Sendable {
    case discovery, start, use, success, failure
}

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warning, error, none
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Property values allowed by the contract: string (≤256 chars), finite number, bool.
public enum PropertyValue: Sendable, Equatable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            // Encode integral values without a fractional part so `minutes: 30` stays `30` on the wire.
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        self = .string(try c.decode(String.self))
    }
}

public struct Options: Sendable {
    /// Ingest endpoint. Defaults to the hosted Union ingest.
    public var endpoint: URL = URL(string: "https://union-ingest.office-927.workers.dev/v1/batch")!
    /// Overrides automatic detection (DEBUG → development, sandbox receipt → testflight, else production).
    public var environment: Environment? = nil
    /// Flush when this many events are queued.
    public var flushAt: Int = 20
    /// Periodic flush while foregrounded.
    public var flushInterval: TimeInterval = 10
    /// FIFO eviction beyond this many queued events (offline for a long time).
    public var maxQueuedEvents: Int = 1000
    /// Swizzles `UIViewController.viewDidAppear` to emit `$screen_view`. Off by default; SwiftUI apps use `.trackScreen`.
    public var automaticScreenTracking: Bool = false
    public var logLevel: LogLevel = .warning
    /// Receives every SDK log line; useful to forward into the host app's logger or the debug inspector.
    public var logHandler: (@Sendable (LogLevel, String) -> Void)? = nil

    public init() {}
}

enum SDKInfo {
    static let version = "0.1.0"
    static let contractVersion = 1
}
