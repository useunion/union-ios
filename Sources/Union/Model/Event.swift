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
    /// Feature key declared in code (`Union.feature("checkout")`). Allowed on custom events and `$screen_view`.
    var feature: String?
    var role: FeatureRole?

    init(eventId: String, sessionId: String, name: String, timestamp: Int64, screen: String?, properties: [String: PropertyValue]?, feature: String? = nil, role: FeatureRole?) {
        self.eventId = eventId
        self.sessionId = sessionId
        self.name = name
        self.timestamp = timestamp
        self.screen = screen
        self.properties = properties
        self.feature = feature
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case sessionId = "session_id"
        case name, timestamp, screen, properties, feature, role
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
