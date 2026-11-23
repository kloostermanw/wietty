import Foundation

/// At most one resync per viewer per interval.
///
/// A resync makes the hub format the terminal's whole history again, on the one
/// delivery queue every session shares, under that session's lock. A viewer that
/// overflows again and again (a slow link under a build log) would make the hub do
/// that again and again and stall the viewers of every other terminal. So a request
/// that comes sooner than `interval` after the last resync is not run at once: it is
/// folded into one deferred resync that runs when the interval is over, and any
/// further request before then is folded into the same one. While a resync is
/// pending the viewer's `ViewerQueue` already drops data, so waiting costs the viewer
/// nothing but the wait.
///
/// One per viewer, owned by `AttachedViewer`. Its own type rather than part of the
/// hub's `resync` because the rule is about one viewer's socket, not about the
/// terminal, and because it can be tested here with a clock and a scheduler the test
/// drives, with no socket and no sleeping.
package final class ResyncThrottle: @unchecked Sendable {
    /// Nanoseconds on a monotonic clock.
    package typealias Clock = @Sendable () -> UInt64
    /// Runs `work` once, `delay` nanoseconds from now, on any thread.
    package typealias Scheduler = @Sendable (_ delay: UInt64, _ work: @escaping @Sendable () -> Void) -> Void

    /// 250 ms.
    package static let defaultInterval: UInt64 = 250_000_000

    package static let systemClock: Clock = { DispatchTime.now().uptimeNanoseconds }
    package static let systemScheduler: Scheduler = { delay, work in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: delay)),
                                          execute: work)
    }

    private let interval: UInt64
    private let now: Clock
    private let schedule: Scheduler

    private let lock = NSLock()
    /// Dropped by `cancel()`, which is what lets go of whatever it captured (the
    /// viewer's queue and the hub) even while a deferred run is still scheduled.
    private var perform: (@Sendable () -> Void)?
    private var lastRun: UInt64?
    private var deferred = false

    /// - Parameter perform: the resync itself, called outside the lock.
    package init(interval: UInt64 = ResyncThrottle.defaultInterval,
                 now: @escaping Clock = ResyncThrottle.systemClock,
                 schedule: @escaping Scheduler = ResyncThrottle.systemScheduler,
                 perform: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
        self.perform = perform
    }

    /// Asks for a resync: run now when the last one is at least `interval` ago,
    /// otherwise folded into the one deferred run.
    package func request() {
        lock.lock()
        guard let perform, !deferred else {
            lock.unlock()
            return
        }
        let time = now()
        if let lastRun, time &- lastRun < interval {
            deferred = true
            let delay = interval - (time &- lastRun)
            lock.unlock()
            schedule(delay) { [weak self] in self?.runDeferred() }
            return
        }
        lastRun = time
        lock.unlock()
        perform()
    }

    /// Nothing runs after this, a deferred run included.
    package func cancel() {
        lock.lock()
        perform = nil
        deferred = false
        lock.unlock()
    }

    private func runDeferred() {
        lock.lock()
        guard deferred, let perform else {
            lock.unlock()
            return
        }
        deferred = false
        lastRun = now()
        lock.unlock()
        perform()
    }
}
