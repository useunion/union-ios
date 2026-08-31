# Union iOS SDK

Product analytics for iOS apps: live sessions, screens, features, releases. iOS 16+, Swift Package, no third-party dependencies, no IDFA.

## Install

Xcode → File → Add Package Dependencies → this repository URL. Add the `Union` library to your app target.

## 10-minute setup

```swift
import Union

@main
struct MyApp: App {
    init() {
        Union.configure(writeKey: "av_…", privacyMode: .productAnalytics)
    }
    var body: some Scene { WindowGroup { RootView().trackScreen("Root") } }
}
```

That already sends `$first_open`, `$app_install` / `$app_update`, `$session_start` / `$session_end`, `$foreground` / `$background`, and device context (app version + build, iOS version, device model, locale, timezone). The panel's **Live** view shows the first session within seconds.

```swift
Union.screen("WorkoutDetail")                                        // or .trackScreen("WorkoutDetail") in SwiftUI
Union.track("workout_started", properties: ["plan": "strength", "minutes": 30], role: .start)
Union.track("workout_finished", role: .success)
Union.identify(userId: "user_123")                                   // after login (product_analytics only)
Union.identify(userId: "user_123", traits: ["email": "ada@example.com", "name": "Ada"])  // named in the panel
Union.reset()                                                        // on logout
Union.handleDeepLink(url)                                            // from onOpenURL / scene delegate
```

Traits describe the person, so the panel can head a profile with a name instead of an id. Up to 8 keys,
values ≤ 256 characters, merged key by key across calls; `reset()` forgets them with the user id. They are
stored as sent — an app that puts an email or a name here is collecting that data and must declare it in
its own App Privacy answers, which the SDK cannot do on its behalf.

Event names: lowercase `snake_case`, max 64 chars. Properties: up to 32 keys; strings ≤ 256 chars, finite numbers, booleans. Invalid events are logged and dropped — the SDK never throws or crashes your app.

### Options

```swift
var o = Options()
o.environment = .testflight        // default: DEBUG → development, sandbox receipt → testflight, else production
o.automaticScreenTracking = true   // UIKit: swizzles viewDidAppear (container/system controllers ignored)
o.flushAt = 20; o.flushInterval = 10
o.logLevel = .debug
o.logHandler = { level, msg in print("[AV]", level, msg) }
Union.configure(writeKey: "av_…", privacyMode: .productAnalytics, options: o)
```

Write keys are bound to one environment. Use a separate key per build configuration (development / TestFlight / production); a mismatch is reported once in the log and the batch is dropped.

## Privacy modes

| | `strictAnonymous` | `productAnalytics` |
|---|---|---|
| Identifier across sessions | none (`identity: {}`) | pseudonymous `install_id` (Keychain, this device only) + optional `user_id` |
| Panel capabilities | screens, events, versions, features per session | + journeys, retention, repeat usage, cohorts |
| App Privacy | Product Interaction (not linked) | Product Interaction, Device ID, User ID (linked, not tracking) |

Neither mode uses IDFA or requires ATT. IP addresses are truncated server-side before storage; location is coarse (country/region). Don't describe `productAnalytics` data as "fully anonymous".

`Union.optOut()` stops collection and wipes the local queue, identity and session; `optIn()` re-enables. `requestDataDeletion()` is currently `optOut()` — server-side deletion is requested from the panel.

## Delivery guarantees

Events are persisted to an NDJSON queue in Application Support (excluded from backup) and sent in batches (≤100 events / ≤256 KB) every 10 s, at 20 queued events, when the app goes to background, and on `flush()`. Retries keep the same `event_id`, so the server deduplicates. Server responses: partial `400` drops only the rejected events; `401` stops the SDK for this launch; `403` / `429` pause (respecting `Retry-After`); network errors back off exponentially (max 5 min). Sessions end after 30 minutes of inactivity — the same rule the server applies.

## Privacy manifest

`PrivacyInfo.xcprivacy` ships with the package (Product Interaction, Device ID, User ID, Other Diagnostic Data — analytics purpose, no tracking; UserDefaults reason `CA92.1`). If you use `strictAnonymous`, remove the Device ID and User ID entries in your app's own manifest answers.

## Development

```
swift test            # runs on macOS host (UIKit parts are compiled out)
```

`Tests/UnionTests/Fixtures/event-batch.v1.json` is copied from the platform repo (`packages/contract/schema`); the schema-conformance test validates every encoded batch against it.
