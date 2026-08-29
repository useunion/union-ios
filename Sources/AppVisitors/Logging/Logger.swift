import Foundation
#if canImport(os)
import os
#endif

struct SDKLogger: Sendable {
    let level: LogLevel
    let handler: (@Sendable (LogLevel, String) -> Void)?

    #if canImport(os)
    private static let osLogger = os.Logger(subsystem: "com.appvisitors.sdk", category: "AppVisitors")
    #endif

    func log(_ l: LogLevel, _ message: @autoclosure () -> String) {
        guard l >= level, l != .none else { return }
        let text = message()
        if let handler { handler(l, text); return }
        #if canImport(os)
        switch l {
        case .debug: Self.osLogger.debug("\(text, privacy: .public)")
        case .info: Self.osLogger.info("\(text, privacy: .public)")
        case .warning: Self.osLogger.warning("\(text, privacy: .public)")
        case .error: Self.osLogger.error("\(text, privacy: .public)")
        case .none: break
        }
        #else
        print("[AppVisitors] \(text)")
        #endif
    }
}
