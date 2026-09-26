import Foundation

/// development → DEBUG builds; testflight → sandbox receipt; production otherwise. Override with `Options.environment`.
/// One write key serves every build: the server stores the environment this reports. Keys created before
/// server migration 0090 are still bound to one environment, and a mismatch is refused there.
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
