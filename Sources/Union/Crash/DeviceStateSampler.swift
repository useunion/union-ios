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
enum DeviceStateSampler {
    static func sample() -> DeviceStateWire {
        var state = DeviceStateWire()
        state.totalMemoryBytes = Int(ProcessInfo.processInfo.physicalMemory)
        state.freeMemoryBytes = availableMemory()
        state.freeDiskBytes = availableDisk()
        state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        state.jailbroken = jailbroken()

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
