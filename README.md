# Union iOS SDK

Product analytics and crash reporting for iOS apps: live sessions, screens, features, releases, crashes. iOS 16+, Swift Package, no third-party dependencies, no IDFA.

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

## Features

Declare a feature where its events are sent, and the funnel builds itself:

```swift
let checkout = Union.feature("checkout")
checkout.screen("Checkout")                                   // discovery — saw the screen
checkout.start("checkout_started")
checkout.use("shipping_selected")
checkout.success("order_placed", properties: ["total": 49.9])
checkout.failure("payment_failed")
```

A declaration is a definition, not a hint. From production and TestFlight builds the server creates the
feature (or adds the new events to one the panel already has) — no inbox step — and the panel refines
it: rename it, set an owner, add events. Edits made in the panel are kept on later syncs. Development
builds only pre-fill the panel's editor, so experimenting with names does not create features. A typo
in the key creates a second feature; it shows up as "Declared in code" with its key and is fixed by
archiving. Keys follow the event-name rules (`snake_case`, max 64 chars). `Union.track(_:feature:role:)`
is the same thing without the handle.

## Crashes, hangs and non-fatals

On by default. `configure` installs the handlers — signals, mach exceptions, `NSException` — and a
watchdog that notices when the main thread stops answering. Nothing else is needed:

```swift
Union.recordError("PaymentFailed", reason: "card_declined")   // a caught error, counted separately
Union.recordError(error)                                       // same, from a Swift Error
Union.setCrashKey("plan", "pro")                               // ≤ 8 labels on every later report
Union.leaveBreadcrumb("retrying_upload")                       // a name in the trail — never a value
```

**A crash is not sent by the process that died.** The handler writes it to disk and the SDK uploads it
on the next launch, so a crash appears minutes later, days later, or — for someone who uninstalls —
never. That is why the panel's crash-free rate is a ceiling for a window that is still filling, and
why "no crashes today" is not the same claim as "a stable day".

There are two switches and both are on by default: `Options.crashReporting` here, and the project's
own **crash reporting** setting in Union. Turning the project's off does not stop the upload — it
turns it into a recorded refusal, so nothing is stored and nothing is silently lost either way.

```swift
var o = Options()
o.crashReporting = false     // installs nothing at all: no handlers, no watchdog, no crash directory
o.hangDetection = true       // main-thread freezes, reported as `hang` — never added to crash counts
o.hangThreshold = 2          // seconds unanswered before it counts as a hang
```

Symbols are not part of this. Frames travel as image UUID + offset, which is the one form that is
identical with and without a dSYM, and the panel hands you the exact `atos` command per image. So
uploading dSYMs later can enrich an issue without regrouping its history — and issues grouped without
symbols cover one build, which the panel says out loud.

Custom keys are app-authored strings about a person, so they are refused in `strictAnonymous` for the
same reason `identify` is, and — like traits — an app that puts an identifier there is collecting it
and answers for it in its own App Privacy disclosures. Breadcrumbs have no field for a value at all.

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

## Linking purchases

Union joins purchases, renewals and refunds to a person through Apple's `appAccountToken`, which the App Store
echoes on every server notification. Set it from the install id when you start a purchase:

```swift
try await product.purchase(options: Union.installUUID.map { [.appAccountToken($0)] } ?? [])
```

`Union.installUUID` is the install id as a `UUID` — `nil` before `configure(…)` and in `strictAnonymous`. The token
has to be a UUID: the App Store accepts any other value without complaining and it links nothing. Purchases made
before you set it cannot be linked afterwards, so set it before your first release that sells anything.

Using RevenueCat instead? Set the subscriber attribute `union_install_id` to `Union.installId`, and call
`Union.identify(userId:)` with the same id you give RevenueCat as `app_user_id`.

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
