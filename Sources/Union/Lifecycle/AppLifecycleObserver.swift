import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Bridges UIApplication notifications into the pipeline. Background flush runs inside a background task
/// (≈5 s budget); the server's session timeout is authoritative if the app is killed first.
@MainActor
final class AppLifecycleObserver {
    private let pipeline: EventPipeline
    // Written once in init on the main actor, read in deinit; NotificationCenter tokens are safe to remove from any thread.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init(pipeline: EventPipeline) {
        self.pipeline = pipeline
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.background() }
        })
        tokens.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.pipeline.willEnterForeground() }
        })
        tokens.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.pipeline.willTerminate() }
        })
    }

    private func background() {
        let app = UIApplication.shared
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = app.beginBackgroundTask(withName: "Union.flush") {
            app.endBackgroundTask(taskId)
            taskId = .invalid
        }
        Task {
            await pipeline.didEnterBackground()
            await MainActor.run {
                if taskId != .invalid { app.endBackgroundTask(taskId) }
            }
        }
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }
}
#endif
