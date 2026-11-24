import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// A clock and a scheduler the test moves by hand, so the rate limit is tested
/// without sleeping.
private final class ManualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 1_000_000_000
    private var jobs: [(due: UInt64, work: @Sendable () -> Void)] = []

    var now: UInt64 { lock.lock(); defer { lock.unlock() }; return current }
    var scheduledCount: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }

    var clock: ResyncThrottle.Clock { { [unowned self] in self.now } }
    var scheduler: ResyncThrottle.Scheduler {
        { [unowned self] delay, work in
            self.lock.lock()
            self.jobs.append((self.current + delay, work))
            self.lock.unlock()
        }
    }

    /// Moves the clock and runs every job that has come due, in order.
    func advance(by nanoseconds: UInt64) {
        lock.lock()
        current += nanoseconds
        let due = jobs.filter { $0.due <= current }
        jobs.removeAll { $0.due <= current }
        lock.unlock()
        for job in due { job.work() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func add() { lock.lock(); count += 1; lock.unlock() }
}

/// A streamer that keeps each viewer's sink and each resync's answer for the test
/// to use.
private final class ScriptedStreamer: ScreenStreaming, @unchecked Sendable {
    struct Claim: Equatable {
        let id: UUID
        let cols: Int
        let rows: Int
    }

    private let lock = NSLock()
    private var sink: (@Sendable (StreamMessage) -> Void)?
    private var answers: [@Sendable () -> Void] = []
    private(set) var resyncIds: [UUID] = []
    private(set) var detached: [UUID] = []
    let id = UUID()
    /// Run inside `attach`, before it returns, as the hub's delivery queue may.
    var duringAttach: ((@Sendable (StreamMessage) -> Void) -> Void)?

    func attach(session: String, resize: ResizeMode,
                onMessage: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        lock.lock(); sink = onMessage; lock.unlock()
        onMessage(.resize(cols: 80, rows: 24, own: false))
        onMessage(.snapshot([0x41]))
        duringAttach?(onMessage)
        return id
    }
    func detach(connectionId: UUID) { lock.lock(); detached.append(connectionId); lock.unlock() }
    func send(session: String, bytes: [UInt8]) {}
    func resync(connectionId: UUID, onUnavailable: @escaping @Sendable () -> Void) {
        lock.lock(); resyncIds.append(connectionId); answers.append(onUnavailable); lock.unlock()
    }
    func stop() {}
    private var claimList: [Claim] = []
    func claim(connectionId: UUID, cols: Int, rows: Int) {
        lock.lock(); claimList.append(Claim(id: connectionId, cols: cols, rows: rows)); lock.unlock()
    }
    /// Every claim made, in order.
    var claims: [Claim] { lock.lock(); defer { lock.unlock() }; return claimList }

    func deliver(_ message: StreamMessage) {
        lock.lock(); let sink = self.sink; lock.unlock()
        sink?(message)
    }
    var resyncCount: Int { lock.lock(); defer { lock.unlock() }; return resyncIds.count }
    /// Answers the oldest unanswered resync with "no snapshot".
    func answerUnavailable() {
        lock.lock(); let answer = answers.removeFirst(); lock.unlock()
        answer()
    }
}

/// Drains what a queue holds right now, without waiting for more.
private func drain(_ queue: ViewerQueue) async -> [StreamMessage] {
    var taken: [StreamMessage] = []
    queue.finish()
    while let message = await queue.next() { taken.append(message) }
    return taken
}

@Suite struct ResyncThrottleTests {
    private let interval: UInt64 = 250_000_000

    /// A burst gives one resync at once and exactly one more when the interval is
    /// over, however many requests the burst held.
    @Test func aBurstGivesOneResyncAtOnceAndOneMoreAfterTheInterval() {
        let time = ManualTime()
        let runs = Counter()
        let throttle = ResyncThrottle(interval: interval, now: time.clock,
                                      schedule: time.scheduler) { runs.add() }
        throttle.request()
        #expect(runs.value == 1)
        for _ in 0..<20 { throttle.request() }
        #expect(runs.value == 1)
        #expect(time.scheduledCount == 1)

        time.advance(by: interval - 1)
        #expect(runs.value == 1)
        time.advance(by: 1)
        #expect(runs.value == 2)

        // Nothing else was folded in, so nothing else comes.
        time.advance(by: 10 * interval)
        #expect(runs.value == 2)
    }

    /// The deferred run counts as the last one: a request just after it waits a
    /// full interval again.
    @Test func theDeferredRunStartsTheNextInterval() {
        let time = ManualTime()
        let runs = Counter()
        let throttle = ResyncThrottle(interval: interval, now: time.clock,
                                      schedule: time.scheduler) { runs.add() }
        throttle.request()
        time.advance(by: 100_000_000)
        throttle.request()
        time.advance(by: 150_000_000)
        #expect(runs.value == 2)
        throttle.request()
        #expect(runs.value == 2)
        time.advance(by: interval)
        #expect(runs.value == 3)
    }

    /// A request an interval or more after the last run runs at once.
    @Test func aRequestAfterTheIntervalRunsAtOnce() {
        let time = ManualTime()
        let runs = Counter()
        let throttle = ResyncThrottle(interval: interval, now: time.clock,
                                      schedule: time.scheduler) { runs.add() }
        throttle.request()
        time.advance(by: interval)
        throttle.request()
        #expect(runs.value == 2)
        #expect(time.scheduledCount == 0)
    }

    /// Cancelled before the deferred run fires: nothing runs, and what the resync
    /// captured is let go at once, while the scheduled job still exists.
    @Test func aCancelledThrottleRunsNothingAndLetsGoOfItsResync() {
        final class Captured: Sendable {}
        let time = ManualTime()
        let runs = Counter()
        weak var released: Captured?
        let throttle: ResyncThrottle
        do {
            let captured = Captured()
            released = captured
            throttle = ResyncThrottle(interval: interval, now: time.clock,
                                      schedule: time.scheduler) { _ = captured; runs.add() }
        }
        throttle.request()
        throttle.request()
        #expect(time.scheduledCount == 1)
        #expect(released != nil)

        throttle.cancel()
        #expect(released == nil)
        time.advance(by: interval)
        throttle.request()
        #expect(runs.value == 1)
    }
}

@Suite struct AttachedViewerTests {
    private let interval: UInt64 = 250_000_000

    /// The hello is queued ahead of what the attach delivers.
    @Test func theGreetingComesBeforeTheAttach() async {
        let streamer = ScriptedStreamer()
        let viewer = AttachedViewer(streamer: streamer, session: "gt:1", resize: .repaint,
                                    greeting: .hello(protocolVersion: 2, session: nil, resize: nil))
        #expect(await drain(viewer.queue) == [
            .hello(protocolVersion: 2, session: nil, resize: nil),
            .resize(cols: 80, rows: 24, own: false),
            .snapshot([0x41]),
        ])
        viewer.close()
    }

    /// Overflows in a row are rate limited per viewer, and every resync that cannot
    /// be answered reaches the queue: the data that follows is accepted again.
    @Test func overflowsAreRateLimitedAndAnUnavailableResyncReachesTheQueue() async {
        let time = ManualTime()
        let streamer = ScriptedStreamer()
        let viewer = AttachedViewer(streamer: streamer, session: "gt:1", resize: .repaint,
                                    greeting: nil, limit: 4, interval: interval,
                                    now: time.clock, schedule: time.scheduler)
        streamer.deliver(.data([1, 2, 3, 4, 5]))
        #expect(streamer.resyncCount == 1)
        #expect(streamer.resyncIds == [streamer.id])
        // Pending: data is dropped.
        streamer.deliver(.data([8]))

        // Unanswerable: the queue takes data again.
        streamer.answerUnavailable()
        streamer.deliver(.data([9]))
        #expect(await viewer.queue.next() == .resize(cols: 80, rows: 24, own: false))
        #expect(await viewer.queue.next() == .data([9]))
        // A second overflow at once is held back by the interval.
        streamer.deliver(.data([1, 2, 3, 4, 5]))
        #expect(streamer.resyncCount == 1)
        time.advance(by: interval)
        #expect(streamer.resyncCount == 2)
        streamer.answerUnavailable()
        streamer.deliver(.data([7]))

        #expect(await drain(viewer.queue) == [.data([7])])
        viewer.close()
    }

    /// A viewer closed while a resync is deferred gets none, the streamer forgets
    /// it, and nothing the viewer built is kept alive by the scheduled job.
    @Test func aViewerClosedBeforeTheDeferredResyncGetsNoneAndLeaksNothing() {
        let time = ManualTime()
        let streamer = ScriptedStreamer()
        weak var released: AttachedViewer?
        do {
            let viewer = AttachedViewer(streamer: streamer, session: "gt:1", resize: .repaint,
                                        greeting: nil, limit: 4, interval: interval,
                                        now: time.clock, schedule: time.scheduler)
            released = viewer
            streamer.deliver(.data([1, 2, 3, 4, 5]))
            streamer.answerUnavailable()
            streamer.deliver(.data([1, 2, 3, 4, 5]))
            #expect(streamer.resyncCount == 1)
            #expect(time.scheduledCount == 1)
            viewer.close()
            viewer.close()
            #expect(streamer.detached == [streamer.id])
        }
        time.advance(by: interval)
        #expect(streamer.resyncCount == 1)
        #expect(released == nil)
    }

    /// An overflow reported before `attach` returned the id is not lost: the resync
    /// is asked for as soon as the id is known.
    @Test func anOverflowBeforeTheIdIsKnownIsResyncedOnceItIs() {
        let streamer = ScriptedStreamer()
        streamer.duringAttach = { sink in sink(.data([1, 2, 3, 4, 5])) }
        let viewer = AttachedViewer(streamer: streamer, session: "gt:1", resize: .repaint,
                                    greeting: nil, limit: 4)
        #expect(streamer.resyncIds == [streamer.id])
        viewer.close()
    }
}
