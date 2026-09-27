import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// development → DEBUG builds; testflight → sandbox receipt; production otherwise. Override with `Options.environment`.
/// One write key serves every build: the server stores the environment this reports. Keys created before
/// server migration 0090 are still bound to one environment, and a mismatch is refused there.
///
/// With one key, a wrong answer here is no longer refused anywhere: a TestFlight build read as production
/// lands in the App Store numbers silently. So the synchronous guess is only the first answer, and
/// `refined()` asks StoreKit's signed `AppTransaction` — the source Apple documents for this question,
/// where `appStoreReceiptURL` is deprecated since iOS 18 and a receipt may simply not be on disk yet.
enum EnvironmentDetector {
    static func detect(bundle: Bundle = .main) -> Environment {
        #if DEBUG
        return .development
        #else
        if bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return .testflight }
        return .production
        #endif
    }

    /// The environment according to `AppTransaction`, or `nil` when StoreKit cannot say (no network on a
    /// first launch, an unverified transaction, a platform without StoreKit). `nil` keeps the first guess:
    /// an unanswered question is not an answer. A DEBUG build never asks — it is development by definition.
    static func refined() async -> Environment? {
        #if DEBUG
        return nil
        #elseif canImport(StoreKit)
        guard let result = try? await AppTransaction.shared else { return nil }
        // Only a verified transaction is Apple's word; an unverified one is exactly what a guess looks like.
        guard case .verified(let transaction) = result else { return nil }
        return environment(for: transaction.environment)
        #else
        return nil
        #endif
    }

    #if canImport(StoreKit)
    /// Unknown values map to `nil` rather than to a default: Apple adding a case must not quietly become
    /// "production".
    static func environment(for storeKit: AppStore.Environment) -> Environment? {
        switch storeKit {
        case .production: return .production
        case .sandbox: return .testflight
        case .xcode: return .development
        default: return nil
        }
    }
    #endif
}
