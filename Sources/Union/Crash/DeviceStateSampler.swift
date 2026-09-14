import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(os)
import os
#endif

/// Samples the device state a handler cannot read for itself.
///
/// Every field is optional and stays absent when we did not get an answer. That is the same refusal
/// the server makes against `COALESCE(col, 0)`: a device that did not report free memory did not
/// report having none, and a crash rendered as "0 bytes free" would send someone hunting a memory
/// bug that the data never claimed.
/// Split in two, by **what the field costs to read**, not by what it describes.
///
/// `interfaceSample` is UIKit and two `ProcessInfo` properties: main-thread-only, and cheap enough to
/// take on whatever thread asked. `systemSample` is the filesystem — a volume-capacity stat and the
/// jailbreak probe, which stats six paths and attempts a write outside the sandbox. Those ran on the
/// main thread on every foreground transition and every five-second resample, which is the same
/// mistake as the sidecar write that produced a `MainThreadHang`, in a place nobody would look for
/// a file operation.
enum DeviceStateSampler {
    /// Everything, for a caller already off the main thread. `interfaceSample` returns nothing from
    /// UIKit there, which is the documented behaviour above and not a new loss.
    static func sample() -> DeviceStateWire {
        merged(interface: interfaceSample(), system: systemSample())
    }

    /// The filesystem half. Safe anywhere, and belongs nowhere near the main thread.
    static func systemSample() -> DeviceStateWire {
        var state = DeviceStateWire()
        state.freeDiskBytes = availableDisk()
        state.jailbroken = isJailbroken
        return state
    }

    static func merged(interface: DeviceStateWire, system: DeviceStateWire) -> DeviceStateWire {
        var out = interface
        out.freeDiskBytes = system.freeDiskBytes
        out.jailbroken = system.jailbroken
        return out
    }

    static func interfaceSample() -> DeviceStateWire {
        var state = DeviceStateWire()
        state.totalMemoryBytes = Int(ProcessInfo.processInfo.physicalMemory)
        state.freeMemoryBytes = availableMemory()
        state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        #if canImport(UIKit) && !os(watchOS)
        // Both of these are main-thread-only. Off the main thread they are left absent rather than
        // read anyway: UIKit's answer from a background thread is not a measurement.
        if Thread.isMainThread {
            let device = UIDevice.current
            /*
             * Battery is read only if the app already turned monitoring on. Enabling it here would
             * change the host app's behaviour — it starts notifications and keeps the level updated —
             * and an analytics SDK switching on a device subsystem to decorate a crash report is not
             * a trade the app agreed to.
             */
            if device.isBatteryMonitoringEnabled {
                let level = device.batteryLevel
                state.batteryLevel = level < 0 ? nil : Double(level)
                switch device.batteryState {
                case .unplugged: state.batteryState = "unplugged"
                case .charging: state.batteryState = "charging"
                case .full: state.batteryState = "full"
                default: state.batteryState = "unknown"
                }
            }
            switch device.orientation {
            case .portrait, .portraitUpsideDown: state.orientation = "portrait"
            case .landscapeLeft, .landscapeRight: state.orientation = "landscape"
            default: state.orientation = "unknown"
            }
        }
        #endif
        return state
    }

    /// What the app may still allocate, which is the number an OOM is about — not system-wide free
    /// memory, which says nothing about a per-process jetsam limit.
    static func availableMemory() -> Int? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 13.0, *) { return Int(os_proc_available_memory()) }
        return nil
        #else
        return nil
        #endif
    }

    static func availableDisk() -> Int? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Int(capacity)
    }

    /// Answered once per process. The device is not jailbroken between one foreground and the next,
    /// and the check is six `stat`s and a write attempt — re-running it per sample paid that price
    /// for an answer that cannot have changed.
    static let isJailbroken: Bool? = jailbroken()

    /**
     * A jailbreak check, and the reason it is a tri-state.
     *
     * `false` means we looked and found nothing; absent means we did not look. On the simulator we do
     * not look, because every one of these paths exists on a Mac and a simulator build would report
     * every developer's machine as jailbroken — a false claim about a user's device, made from our
     * own test environment.
     */
    static func jailbroken() -> Bool? {
        #if targetEnvironment(simulator) || os(macOS)
        return nil
        #else
        let markers = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/bin/bash", "/usr/sbin/sshd",
                       "/etc/apt", "/private/var/lib/apt/"]
        if markers.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        // Writing outside the sandbox is the check that does not depend on knowing today's tool names.
        let probe = "/private/union_sandbox_probe"
        if (try? "probe".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        return false
        #endif
    }
}
