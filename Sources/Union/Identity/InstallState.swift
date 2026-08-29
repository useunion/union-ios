import Foundation

/// Detects first open / install / reinstall / update from the last seen app version+build (03-mobile-sdk "Automatyczny kontekst").
struct InstallState {
    private static let versionKey = "last_app_version"
    private static let buildKey = "last_app_build"

    enum Outcome: Equatable {
        case firstOpen(reinstall: Bool)
        case updated(previousVersion: String, previousBuild: String)
        case unchanged
    }

    /// `hadPersistentIdentity` = an install id already existed in the Keychain (survives reinstall).
    static func evaluate(store: KeyValueStore, device: DeviceContext, hadPersistentIdentity: Bool) -> Outcome {
        let prevVersion = store.string(forKey: versionKey)
        let prevBuild = store.string(forKey: buildKey)
        store.set(device.appVersion, forKey: versionKey)
        store.set(device.appBuild, forKey: buildKey)
        guard let pv = prevVersion, let pb = prevBuild else { return .firstOpen(reinstall: hadPersistentIdentity) }
        if pv != device.appVersion || pb != device.appBuild { return .updated(previousVersion: pv, previousBuild: pb) }
        return .unchanged
    }
}
