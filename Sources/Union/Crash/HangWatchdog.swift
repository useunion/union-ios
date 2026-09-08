import Foundation

/// Notices when the main thread stops answering.
///
/// A hang is not a crash and is measured differently: nothing dies, so there is no signal, no record
/// written by a handler and no next launch to wait for. What there is, is a thread that is not
/// responding — so the watchdog lives on its own thread, pings the main queue, and reports when a
/// ping goes unanswered for longer than the threshold.
///
/// Two rules keep it from lying. It reports **once per episode**, because a main thread blocked for
/// twelve seconds is one hang and not forty-eight; and it reports the duration it actually measured
/// at the moment it gave up waiting, never the threshold — "blocked for at least 2s" and "blocked for
/// 11s" are different facts about somebody's app.
final class HangWatchdog: @unchecked Sendable {
    /// How often a ping is sent. Fine-grained enough that the reported duration is close to the real
    /// one, coarse enough to be invisible: one empty block on the main queue per tick.
    private static let tick: TimeInterval = 0.25

    private let threshold: TimeInterval
    private let onHang: (TimeInterval, mach_port_t) -> Void
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private var pingSentAt: Date?
    private var answered = true
    private var reportedThisEpisode = false
    private var mainThreadPort: mach_port_t = 0

    init(threshold: TimeInterval, onHang: @escaping (TimeInterval, mach_port_t) -> Void) {
        self.threshold = threshold
        self.onHang = onHang
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        // The main thread's mach port, taken on the main thread itself, because that is the only
        // place `pthread_self()` means the main thread. The watchdog needs it to capture the stack of
        // the thread that is stuck rather than its own.
        DispatchQueue.main.async { [weak self] in
            let port = pthread_mach_thread_np(pthread_self())
            self?.lock.withLock { self?.mainThreadPort = port }
        }

        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "app.union.hang-watchdog"
        // Below default: a watchdog that competes for CPU with the work it is timing would report
        // hangs it helped cause.
        thread.qualityOfService = .utility
        lock.withLock { self.thread = thread }
        thread.start()
    }

    func stop() {
        lock.withLock { running = false }
    }

    private func loop() {
        while lock.withLock({ running }) {
            Thread.sleep(forTimeInterval: HangWatchdog.tick)
            guard lock.withLock({ running }) else { return }

            var toReport: (TimeInterval, mach_port_t)?
            lock.lock()
            if answered {
                // Previous ping came back: start a new measurement and close any episode.
                answered = false
                reportedThisEpisode = false
                pingSentAt = Date()
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.lock.withLock { self?.answered = true }
                }
                continue
            }
            let waiting = pingSentAt.map { Date().timeIntervalSince($0) } ?? 0
            if waiting >= threshold, !reportedThisEpisode, mainThreadPort != 0 {
                reportedThisEpisode = true
                toReport = (waiting, mainThreadPort)
            }
            lock.unlock()

            if let (duration, port) = toReport { onHang(duration, port) }
        }
    }
}
