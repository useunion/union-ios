import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum DeviceContextProvider {
    static func current() -> DeviceContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceContext(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            appBuild: info["CFBundleVersion"] as? String ?? "0",
            sdkVersion: SDKInfo.version,
            osVersion: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            deviceModel: hardwareModel(),
            locale: String(Locale.current.identifier.prefix(16)),
            timezone: String(TimeZone.current.identifier.prefix(64))
        )
    }

    /// e.g. "iPhone16,1" — the machine identifier, not the marketing name (no PII, stable across OS versions).
    static func hardwareModel() -> String {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? model
        #else
        return String(model.prefix(64))
        #endif
    }
}
