import Foundation

struct DeviceContext: Codable, Sendable, Equatable {
    var appVersion: String
    var appBuild: String
    var sdkVersion: String
    /// Contract literal: the v1 wire format is iOS-only.
    var osName: String = "iOS"
    var osVersion: String
    var deviceModel: String
    var locale: String
    var timezone: String

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case appBuild = "app_build"
        case sdkVersion = "sdk_version"
        case osName = "os_name"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case locale, timezone
    }
}

/// `identity` is always present; both keys are omitted (never null) when absent. Empty in strict_anonymous.
struct Identity: Codable, Sendable, Equatable {
    var installId: String?
    var userId: String?

    enum CodingKeys: String, CodingKey {
        case installId = "install_id"
        case userId = "user_id"
    }

    static let anonymous = Identity()
}

struct EventBatch: Codable, Sendable {
    var contractVersion: Int = SDKInfo.contractVersion
    var batchId: String
    var environment: Environment
    var privacyMode: PrivacyMode
    var sentAt: Int64
    var device: DeviceContext
    var identity: Identity
    var events: [Event]

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case batchId = "batch_id"
        case environment
        case privacyMode = "privacy_mode"
        case sentAt = "sent_at"
        case device, identity, events
    }
}

enum WireCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()
}
