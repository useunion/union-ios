import Foundation

/// One event on the wire (`events[]` in the batch). Keys are snake_case per contract; no extra fields allowed.
struct Event: Codable, Sendable, Equatable {
    var eventId: String
    var sessionId: String
    var name: String
    /// Client wall-clock time in ms since epoch.
    var timestamp: Int64
    var screen: String?
    var properties: [String: PropertyValue]?
    var role: FeatureRole?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case sessionId = "session_id"
        case name, timestamp, screen, properties, role
    }
}

/// Reserved `$`-prefixed names emitted by the SDK itself; customers cannot track these directly.
enum AutoEvent: String {
    case firstOpen = "$first_open"
    case sessionStart = "$session_start"
    case sessionEnd = "$session_end"
    case foreground = "$foreground"
    case background = "$background"
    case screenView = "$screen_view"
    case appInstall = "$app_install"
    case appUpdate = "$app_update"
    case deepLink = "$deep_link"
}
