import Foundation

/*
 * The wire shape of a crash report, mirroring `packages/contract/src/crash-batch.ts`.
 *
 * A separate contract from `EventBatch` and not a widening of it: a dump of forty-eight threads at a
 * hundred and twenty-eight frames is unrepresentable in `Event.properties`, and `Event.timestamp` is
 * one clock where a crash has three. `Tests/UnionTests/Fixtures/crash-batch.v1.json` is the same
 * schema the server validates against, and CrashModelTests encodes a real report through it, so a
 * field renamed on either side fails here rather than in production.
 */

/// What died, and how badly. Never summed into one "crashes" figure — three severities, three numbers.
public enum CrashKind: String, Codable, Sendable {
    case fatal, nonfatal, hang
    /// Android's word for a frozen app. iOS never sends it; it exists so the column never changes shape.
    case anr
}

struct CrashFrameWire: Codable, Sendable, Equatable {
    /// 0 is innermost. Explicit rather than array order, so a truncated dump can say where it cut.
    var n: Int
    var addr: String
    /// Index into `CrashReportWire.images`; `nil` encodes as `null` — the address is in no known image.
    var image: Int?
    var offset: Int?
    var symbol: String?

    /// `image`/`offset` are nullable on the wire, not optional, so an unknown image cannot be omitted
    /// into looking like a field we forgot to send.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(n, forKey: .n)
        try c.encode(addr, forKey: .addr)
        try c.encode(image, forKey: .image)
        try c.encode(offset, forKey: .offset)
        try c.encodeIfPresent(symbol, forKey: .symbol)
    }
}

struct BinaryImageWire: Codable, Sendable, Equatable {
    var name: String
    /// Uppercase hex, no dashes: this is the join key against an uploaded dSYM's `LC_UUID`, and a
    /// difference in spelling looks exactly like holding no dSYM for the build.
    var uuid: String
    var loadAddr: String
    var size: Int?
    var arch: String?
    var isApp: Bool

    enum CodingKeys: String, CodingKey {
        case name, uuid, size, arch
        case loadAddr = "load_addr"
        case isApp = "is_app"
    }
}

struct CrashThreadWire: Codable, Sendable, Equatable {
    var index: Int
    var name: String?
    var crashed: Bool
    var frames: [CrashFrameWire]
    /// True when frames past the cap were dropped, so a cut dump never reads as a short stack.
    var framesTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case index, name, crashed, frames
        case framesTruncated = "frames_truncated"
    }
}

/// The signal name, never its number: numbers differ per platform, `SIGSEGV` does not.
struct CrashSignalWire: Codable, Sendable, Equatable {
    var name: String
    var code: String?
    var machException: String?
    var machCode: String?
    var machSubcode: String?
    var faultAddr: String?

    enum CodingKeys: String, CodingKey {
        case name, code
        case machException = "mach_exception"
        case machCode = "mach_code"
        case machSubcode = "mach_subcode"
        case faultAddr = "fault_addr"
    }
}

struct CrashExceptionWire: Codable, Sendable, Equatable {
    var type: String
    /// The app's own message: PII-bearing by nature, kept because it is half the diagnostic value,
    /// and excluded from the fingerprint so a redaction change can never regroup history.
    var reason: String?
}

/// Every field optional, and absent stays absent: a device that did not report free memory did not
/// have zero free memory.
struct DeviceStateWire: Codable, Sendable, Equatable {
    var orientation: String?
    var freeMemoryBytes: Int?
    var totalMemoryBytes: Int?
    var freeDiskBytes: Int?
    var batteryLevel: Double?
    var batteryState: String?
    var jailbroken: Bool?
    var lowPowerMode: Bool?
    var inForeground: Bool?
    var uptimeMs: Int?

    enum CodingKeys: String, CodingKey {
        case orientation, jailbroken
        case freeMemoryBytes = "free_memory_bytes"
        case totalMemoryBytes = "total_memory_bytes"
        case freeDiskBytes = "free_disk_bytes"
        case batteryLevel = "battery_level"
        case batteryState = "battery_state"
        case lowPowerMode = "low_power_mode"
        case inForeground = "in_foreground"
        case uptimeMs = "uptime_ms"
    }
}

/// One step before the crash — and deliberately no field a value can occupy. Widening this is a
/// privacy decision, not a refactor: breadcrumbs bypass the event pipeline, so the remote kill
/// switch never filtered them.
struct BreadcrumbWire: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case event, screen, log, state

        /// The byte the C ring buffer stores. Kept here so both sides of the boundary agree in one place.
        var byte: UInt8 {
            switch self {
            case .event: return 1
            case .screen: return 2
            case .log: return 3
            case .state: return 4
            }
        }

        init?(byte: UInt8) {
            switch byte {
            case 1: self = .event
            case 2: self = .screen
            case 3: self = .log
            case 4: self = .state
            default: return nil
            }
        }
    }

    var ts: Int64
    var kind: Kind
    var name: String
}

struct CrashReportWire: Codable, Sendable {
    var crashId: String
    var kind: CrashKind
    /// Cross-checked against `kind` by the contract rather than derived from it: this is the column
    /// every aggregate filters on, and a rejected disagreement beats a pipeline picking a winner.
    var isFatal: Bool
    /// The client's clock at the moment of death. The basis for which day this crash belongs to.
    var crashedAt: Int64
    var sessionId: String?
    /// Context **at crash time**, not at upload time — the app was very likely updated in between,
    /// and attributing a crash to the version that reported it would blame the release that fixed it.
    var context: DeviceContext
    var state: DeviceStateWire?
    var signal: CrashSignalWire?
    var exception: CrashExceptionWire?
    var hangDurationMs: Int?
    var images: [BinaryImageWire]
    var threads: [CrashThreadWire]
    var breadcrumbs: [BreadcrumbWire]?
    var customKeys: [String: String]?

    enum CodingKeys: String, CodingKey {
        case kind, context, state, signal, exception, images, threads, breadcrumbs
        case crashId = "crash_id"
        case isFatal = "is_fatal"
        case crashedAt = "crashed_at"
        case sessionId = "session_id"
        case hangDurationMs = "hang_duration_ms"
        case customKeys = "custom_keys"
    }
}

struct CrashBatchWire: Codable, Sendable {
    var contractVersion: Int = CrashSDKInfo.contractVersion
    var batchId: String
    var environment: Environment
    var privacyMode: PrivacyMode
    /// Upload time, deliberately not the same clock as any report's `crashed_at`.
    var sentAt: Int64
    var identity: Identity
    var reports: [CrashReportWire]

    enum CodingKeys: String, CodingKey {
        case environment, identity, reports
        case contractVersion = "contract_version"
        case batchId = "batch_id"
        case privacyMode = "privacy_mode"
        case sentAt = "sent_at"
    }
}

enum CrashSDKInfo {
    /// Versioned independently of the event contract: the two change for different reasons, and an
    /// SDK may support one and not the other.
    static let contractVersion = 1
}

/// Contract limits, mirrored from `LIMITS.crash`. The C core repeats the ones a handler needs.
enum CrashLimits {
    static let maxReportsPerBatch = 8
    static let maxThreads = 48
    static let maxFramesPerThread = 128
    static let maxImages = 512
    static let maxBreadcrumbs = 64
    static let breadcrumbNameMaxLength = 128
    static let reasonMaxLength = 1024
    static let maxCustomKeys = 8
    static let customKeyMaxLength = 40
    static let customValueMaxLength = 256
}

/// Lowercase `0x…`, which is what `HexAddress` in the contract accepts.
func crashHex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
