import Foundation

/// development → DEBUG builds; testflight → sandbox receipt; production otherwise. Override with `Options.environment`.
/// Ship a distinct write key per build configuration: keys are bound to one environment server-side.
enum EnvironmentDetector {
    static func detect(bundle: Bundle = .main) -> Environment {
        #if DEBUG
        return .development
        #else
        if bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return .testflight }
        return .production
        #endif
    }
}
