import Foundation

/// Uncaught Objective-C / Swift exceptions.
///
/// Worth having next to the signal handlers because it is the only place the *thrown thing* is still
/// visible: by the time the process reaches `SIGABRT`, `NSInvalidArgumentException` has become an
/// abort with no name and no reason attached, and every such crash would group together under one
/// meaningless issue.
///
/// `NSSetUncaughtExceptionHandler` takes a bare C function, so the closure has to live in a global —
/// there is nowhere to put a context pointer. The previous handler is kept and called: an app with
/// its own reporter installed keeps receiving its own callback, and swallowing it would make Union
/// the reason another tool went quiet.
enum CrashExceptionBridge {
    typealias Handler = @Sendable (_ type: String, _ reason: String?, _ frames: [UInt64]) -> Void

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var previous: (@convention(c) (NSException) -> Void)?
    private static let lock = NSLock()

    static func install(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        previous = NSGetUncaughtExceptionHandler()
        lock.unlock()

        NSSetUncaughtExceptionHandler { exception in
            CrashExceptionBridge.lock.lock()
            let current = CrashExceptionBridge.handler
            let chain = CrashExceptionBridge.previous
            CrashExceptionBridge.lock.unlock()

            current?(exception.name.rawValue,
                     exception.reason,
                     exception.callStackReturnAddresses.map { UInt64(truncating: $0) })
            /*
             * Then hand it on. The process is going to die either way, and this handler returning is
             * what lets the runtime carry on to `abort()` — so Apple's own crash log for this
             * termination still gets written, and the developer can cross-check ours against it.
             */
            chain?(exception)
        }
    }

    /// Restores whatever was installed before. Used by `stop()` and by tests, which must not leave a
    /// handler pointing at a deallocated reporter.
    static func uninstall() {
        lock.lock()
        let chain = previous
        handler = nil
        previous = nil
        lock.unlock()
        NSSetUncaughtExceptionHandler(chain)
    }
}
