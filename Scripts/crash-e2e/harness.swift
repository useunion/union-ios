/*
 * The one thing `swift test` cannot do: let the process die.
 *
 * A test runner that segfaults reports nothing, so `CrashTests` exercises the handler through
 * `union_crash_capture_live` — the same walk, minus dying. That leaves the seam this harness covers:
 * a process that really takes a signal, a handler that really writes from it, and a *second* process
 * that reads the file off disk and uploads it. See `Scripts/crash-e2e.sh`, which drives both modes.
 *
 * Not a package target on purpose: it links the debug build of `Union` with `@testable`, and it exists
 * to be run by hand before a release rather than on every `swift test`.
 *
 *   harness crash  <store-dir> <endpoint>   installs, drops a breadcrumb, then dereferences null
 *   harness report <store-dir> <endpoint>   the next launch: sends whatever the dead one left
 */
import Foundation
import UnionCrashCore
@testable import Union

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: harness <crash|report> <store-dir> <endpoint>\n".utf8))
    exit(2)
}
let mode = args[1]
let dir = URL(fileURLWithPath: args[2])
guard let endpoint = URL(string: args[3]) else { exit(2) }

let device = DeviceContext(appVersion: "9.9.9", appBuild: "42", sdkVersion: SDKInfo.version,
                           osVersion: "18.0", deviceModel: "harness", locale: "pl_PL", timezone: "Europe/Warsaw")
let logger = SDKLogger(level: .debug, handler: { level, message in print("[\(level)] \(message)") })
let store = try CrashStore(directory: dir)
let reporter = CrashReporter(
    config: .init(writeKey: "wk_harness", environment: .production, privacyMode: .productAnalytics,
                  hangThreshold: 2, detectHangs: false, maxStored: 16),
    store: store,
    transport: URLSessionCrashTransport(endpoint: endpoint),
    identityStore: InMemoryIdentityStore(),
    device: device, logger: logger, clock: SystemClock())

switch mode {
case "crash":
    reporter.start(sessionId: "harness-session")
    reporter.breadcrumb(BreadcrumbWire.Kind.screen, "Checkout")
    reporter.setCustomKey("build_flavor", "harness")
    // The sidecar is what makes the record attributable; without it the next launch discards the
    // report, and the run would pass for the wrong reason.
    reporter.waitForPendingWrites()
    print("harness: about to dereference null")
    fflush(stdout)
    // Written this way rather than `UnsafeMutablePointer(bitPattern:)!`, because the force-unwrap
    // traps first and the run would then only ever prove EXC_BREAKPOINT works.
    unsafeBitCast(UInt(0), to: UnsafeMutablePointer<Int>.self).pointee = 1
    print("harness: unreachable — the handler did not fire")
    exit(1)

case "report":
    // A fresh process installs nothing: it only drains what the dead one left behind, which is the
    // half of the design that the live-capture tests cannot reach.
    let done = DispatchSemaphore(value: 0)
    Task { await reporter.flushPending(); done.signal() }
    done.wait()
    print("harness: reports still on disk = \(store.pending(excluding: nil).count)")

default:
    FileHandle.standardError.write(Data("unknown mode \(mode)\n".utf8))
    exit(2)
}
