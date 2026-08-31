import Foundation

/// Union iOS SDK — public facade. All calls are synchronous, thread-safe and never throw or crash the host app;
/// invalid input is logged and dropped. Configure once, as early as possible in app launch.
///
/// ```swift
/// Union.configure(writeKey: "av_…", privacyMode: .productAnalytics)
/// Union.track("workout_started", properties: ["plan": "strength", "minutes": 30], role: .start)
/// ```
public enum Union {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var client: Client?

    private static var shared: Client? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    /// Creates the SDK. Calling twice replaces the previous client (useful in tests / logout flows).
    public static func configure(writeKey: String, privacyMode: PrivacyMode, options: Options = Options()) {
        let c = Client(writeKey: writeKey, privacyMode: privacyMode, options: options)
        lock.lock(); client = c; lock.unlock()
    }

    /// Custom event. `name` must be lowercase snake_case (`workout_started`); `$`-prefixed names are reserved.
    public static func track(_ name: String, properties: [String: PropertyValue] = [:], role: FeatureRole? = nil, screen: String? = nil) {
        guard let p = shared?.pipeline else { return }
        Task { await p.track(name: name, properties: properties, role: role, screen: screen) }
    }

    /// Manual `$screen_view`. Use `.trackScreen(_:)` in SwiftUI or `Options.automaticScreenTracking` in UIKit.
    public static func screen(_ name: String, properties: [String: PropertyValue] = [:]) {
        guard let p = shared?.pipeline else { return }
        Task { await p.screen(name: name, properties: properties) }
    }

    /// Attach your own user id after login, optionally with traits describing the person —
    /// `name`, `email`, `plan`. The panel shows them instead of a raw id, and they are merged
    /// key by key across calls, so `identify(userId:traits:["plan": "pro"])` later does not erase
    /// an email sent earlier. Up to 8 traits, values ≤ 256 characters.
    ///
    /// Traits are stored as sent. An app that puts an email or a name here is collecting that data
    /// and has to say so in its own App Privacy answers — the SDK cannot declare it for you.
    /// Ignored (with a warning) in `strictAnonymous`.
    public static func identify(userId: String, traits: [String: String] = [:]) {
        guard let p = shared?.pipeline else { return }
        Task { await p.identify(userId: userId, traits: traits) }
    }

    /// Logout: forgets the user id and starts a new session. The install id is kept. Safe to call when nobody is
    /// signed in — it does nothing then, so a cold launch that resets before auth restores keeps one session.
    public static func reset() {
        guard let p = shared?.pipeline else { return }
        Task { await p.reset() }
    }

    /// Stops collection and wipes all locally stored data. Persists across launches until `optIn()`.
    public static func optOut() {
        guard let p = shared?.pipeline else { return }
        Task { await p.optOut() }
    }

    public static func optIn() {
        guard let p = shared?.pipeline else { return }
        Task { await p.optIn() }
    }

    /// Today equivalent to `optOut()`. Server-side deletion of already-ingested data is requested from the panel
    /// (Settings → Privacy) until a public deletion API ships.
    public static func requestDataDeletion() { optOut() }

    /// Records `$deep_link { url_scheme, host, path }`. Query strings are never sent.
    public static func handleDeepLink(_ url: URL) {
        guard let p = shared?.pipeline else { return }
        Task { await p.deepLink(url) }
    }

    /// Sends queued events now. The SDK also flushes every `Options.flushInterval`, at `flushAt` events and on background.
    public static func flush() async {
        guard let p = shared?.pipeline else { return }
        await p.flush()
    }

    public static var isConfigured: Bool { shared != nil }
}
