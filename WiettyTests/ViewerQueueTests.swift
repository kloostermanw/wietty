import Foundation
import Testing
import WiettyShared
import WiettyCore

@Suite(.timeLimit(.minutes(1))) struct ViewerQueueTests {
    /// Counts `onOverflow` calls, and can answer one the way the server will: by pushing
    /// a `resize` and a `snapshot` from inside the callback.
    private final class Overflows: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        weak var answerInto: ViewerQueue?
        var count: Int { lock.lock(); defer { lock.unlock() }; return storage }
        func record() {
            lock.lock(); storage += 1; lock.unlock()
            answerInto?.push(.resize(cols: 80, rows: 24, own: false))
            answerInto?.push(.snapshot(Array("fresh".utf8)))
        }
    }

    private static let limit = 64

    private func bytes(_ count: Int, _ value: UInt8 = 0x61) -> [UInt8] {
        [UInt8](repeating: value, count: count)
    }

    private func makeQueue() -> (ViewerQueue, Overflows) {
        let overflows = Overflows()
        let queue = ViewerQueue(limit: Self.limit) { overflows.record() }
        return (queue, overflows)
    }

    /// Finishes the queue and takes everything it still holds.
    private func drain(_ queue: ViewerQueue) async -> [StreamMessage] {
        queue.finish()
        var out: [StreamMessage] = []
        while let message = await queue.next() { out.append(message) }
        return out
    }

    /// Waits until a consumer is parked in `next()`, so the hand over path is what the
    /// test exercises. Should that path be broken, the suite's time limit ends the wait.
    private func waitUntilParked(_ queue: ViewerQueue) async {
        while !queue.hasParkedConsumer { await Task.yield() }
    }

    /// Pushes data until the queue overflows, from a queue holding nothing counted.
    private func overflow(_ queue: ViewerQueue) {
        queue.push(.data(bytes(40)))
        queue.push(.data(bytes(40)))
    }

    // MARK: The brief's eight rules

    @Test func messagesComeOutInOrder() async {
        let (queue, overflows) = makeQueue()
        let sent: [StreamMessage] = [
            .hello(protocolVersion: 2, session: nil, resize: nil),
            .resize(cols: 80, rows: 24, own: true),
            .snapshot(bytes(5)),
            .data(bytes(3, 0x62)),
            .repaint(bytes(4, 0x63)),
            .data(bytes(2, 0x64)),
            .ended,
        ]
        for message in sent { queue.push(message) }
        #expect(await drain(queue) == sent)
        #expect(overflows.count == 0)
    }

    @Test func dataBeyondTheLimitDropsTheQueueAndAsksOnce() async {
        let (queue, overflows) = makeQueue()
        queue.push(.data(bytes(30)))
        queue.push(.repaint(bytes(30)))
        queue.push(.data(bytes(30)))     // 90 > 64
        queue.push(.data(bytes(30)))     // already pending: no second call
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [])
    }

    @Test func whileAResyncIsPendingDataIsDropped() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.push(.data(bytes(1)))
        queue.push(.repaint(bytes(1)))
        queue.push(.resize(cols: 100, rows: 30, own: false))
        queue.push(.data(bytes(1)))
        queue.push(.ended)
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [.resize(cols: 100, rows: 30, own: false), .ended])
    }

    @Test func aSnapshotIsNeverCountedAgainstTheLimit() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        let big = bytes(12 << 20)
        queue.push(.snapshot(big))
        queue.push(.data(bytes(3)))                 // fits, unless the snapshot was counted
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [.snapshot(big), .data(bytes(3))])
    }

    @Test func dataAfterTheSnapshotIsDeliveredAfterIt() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.push(.data(bytes(1)))                 // dropped: resync pending
        queue.push(.snapshot(bytes(5)))
        queue.push(.data(bytes(3, 0x62)))
        queue.push(.repaint(bytes(3, 0x63)))
        #expect(await drain(queue) == [.snapshot(bytes(5)), .data(bytes(3, 0x62)), .repaint(bytes(3, 0x63))])
        #expect(overflows.count == 1)
    }

    @Test func anOverflowWithAnUnsentSnapshotReplacesThatSnapshot() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.push(.snapshot(bytes(1 << 20)))      // never taken
        queue.push(.data(bytes(40)))
        queue.push(.data(bytes(40)))               // past the limit again
        #expect(overflows.count == 2)
        #expect(await drain(queue) == [])
    }

    /// An `ended` queued before an overflow cannot exist (nothing is accepted after it),
    /// so the overflow it survives is the one it arrives during.
    @Test func endedSurvivesAnOverflow() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.push(.ended)
        queue.resyncUnavailable()
        #expect(overflows.count == 1)
        #expect(await queue.next() == .ended)
        queue.finish()
        #expect(await queue.next() == nil)
    }

    @Test func finishEndsNext() async {
        let (queue, _) = makeQueue()
        let waiting = Task { await queue.next() }
        await waitUntilParked(queue)
        queue.finish()
        #expect(await waiting.value == nil)
        #expect(await queue.next() == nil)
    }

    // MARK: Decisions beyond the brief

    @Test func helloAndErrorSurviveAnOverflow() async {
        let (queue, overflows) = makeQueue()
        queue.push(.hello(protocolVersion: 2, session: nil, resize: nil))
        queue.push(.data(bytes(40)))
        queue.push(.error(code: "x", message: "y"))
        queue.push(.repaint(bytes(40)))
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [
            .hello(protocolVersion: 2, session: nil, resize: nil),
            .error(code: "x", message: "y"),
        ])
    }

    @Test func pushAfterFinishIsIgnored() async {
        let (queue, overflows) = makeQueue()
        queue.push(.data(bytes(1)))
        queue.finish()
        queue.push(.data(bytes(2)))
        queue.push(.data(bytes(100)))              // would overflow, but the queue is finished
        queue.push(.ended)
        #expect(await queue.next() == .data(bytes(1)))
        #expect(await queue.next() == nil)
        #expect(overflows.count == 0)
    }

    @Test func finishDrainsWhatIsQueued() async {
        let (queue, _) = makeQueue()
        queue.push(.resize(cols: 80, rows: 24, own: false))
        queue.push(.data(bytes(3)))
        queue.finish()
        #expect(await queue.next() == .resize(cols: 80, rows: 24, own: false))
        #expect(await queue.next() == .data(bytes(3)))
        #expect(await queue.next() == nil)
        #expect(await queue.next() == nil)
    }

    @Test func aWaitingNextIsWokenByAPush() async {
        let (queue, _) = makeQueue()
        let waiting = Task { await queue.next() }
        await waitUntilParked(queue)
        queue.push(.data(bytes(3)))
        #expect(await waiting.value == .data(bytes(3)))
    }

    @Test func dataUpToTheLimitIsKeptAndTakenDataFreesRoom() async {
        let (queue, overflows) = makeQueue()
        queue.push(.data(bytes(32)))
        queue.push(.repaint(bytes(32)))             // exactly the limit: no overflow
        #expect(overflows.count == 0)
        #expect(await queue.next() == .data(bytes(32)))
        queue.push(.data(bytes(32)))                // fits again once the first is taken
        #expect(overflows.count == 0)
        #expect(await drain(queue) == [.repaint(bytes(32)), .data(bytes(32))])
    }

    @Test func onOverflowRunsOutsideTheLockSoItCanAnswerAtOnce() async {
        let overflows = Overflows()
        let queue = ViewerQueue(limit: Self.limit) { overflows.record() }
        overflows.answerInto = queue
        queue.push(.data(bytes(40)))
        queue.push(.data(bytes(40)))                // overflow, answered from the callback
        queue.push(.data(bytes(3)))                 // after the snapshot: delivered
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [
            .resize(cols: 80, rows: 24, own: false),
            .snapshot(Array("fresh".utf8)),
            .data(bytes(3)),
        ])
    }

    @Test func aResizeQueuedBeforeAnOverflowSurvivesIt() async {
        let (queue, overflows) = makeQueue()
        queue.push(.data(bytes(10)))
        queue.push(.resize(cols: 120, rows: 40, own: true))
        queue.push(.data(bytes(60)))                // 70 > 64
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [.resize(cols: 120, rows: 40, own: true)])
    }

    // MARK: ended during a resync

    @Test func anEndedDuringAResyncIsDeliveredAfterTheSnapshot() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.push(.ended)                          // held: the final screen comes first
        queue.push(.resize(cols: 80, rows: 24, own: false))
        queue.push(.snapshot(bytes(5)))
        #expect(overflows.count == 1)
        #expect(await queue.next() == .resize(cols: 80, rows: 24, own: false))
        #expect(await queue.next() == .snapshot(bytes(5)))
        #expect(await queue.next() == .ended)
        queue.finish()
        #expect(await queue.next() == nil)
    }

    @Test func resyncUnavailableReleasesAHeldEndedToAParkedConsumer() async {
        let (queue, _) = makeQueue()
        overflow(queue)
        queue.push(.ended)
        let waiting = Task { await queue.next() }
        await waitUntilParked(queue)
        queue.resyncUnavailable()
        #expect(await waiting.value == .ended)
    }

    @Test func finishReleasesAHeldEnded() async {
        let (queue, _) = makeQueue()
        overflow(queue)
        queue.push(.ended)
        let waiting = Task { await queue.next() }
        await waitUntilParked(queue)
        queue.finish()
        #expect(await waiting.value == .ended)
        #expect(await queue.next() == nil)
    }

    @Test func aPushAfterADeliveredEndedIsIgnored() async {
        let (queue, overflows) = makeQueue()
        queue.push(.data(bytes(3)))
        queue.push(.ended)
        queue.push(.data(bytes(4)))
        queue.push(.data(bytes(100)))               // would overflow
        queue.push(.snapshot(bytes(5)))
        queue.push(.resize(cols: 80, rows: 24, own: false))
        #expect(overflows.count == 0)
        #expect(await drain(queue) == [.data(bytes(3)), .ended])
    }

    @Test func aPushAfterAReleasedEndedIsIgnored() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.push(.ended)
        queue.push(.snapshot(bytes(5)))             // releases the ended behind it
        queue.push(.data(bytes(3)))
        queue.push(.resize(cols: 80, rows: 24, own: false))
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [.snapshot(bytes(5)), .ended])
    }

    @Test func resyncUnavailableWithNothingPendingDoesNothing() async {
        let (queue, overflows) = makeQueue()
        queue.push(.data(bytes(3)))
        queue.resyncUnavailable()
        queue.push(.data(bytes(4)))
        #expect(overflows.count == 0)
        #expect(await drain(queue) == [.data(bytes(3)), .data(bytes(4))])
    }

    @Test func dataFlowsAgainAfterResyncUnavailable() async {
        let (queue, overflows) = makeQueue()
        overflow(queue)
        queue.resyncUnavailable()
        queue.push(.data(bytes(3)))
        #expect(overflows.count == 1)
        #expect(await drain(queue) == [.data(bytes(3))])
    }

    // MARK: Cancellation

    @Test func cancellingAParkedNextReturnsNil() async {
        let (queue, _) = makeQueue()
        let waiting = Task { await queue.next() }
        await waitUntilParked(queue)
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(!queue.hasParkedConsumer)
    }

    @Test func aNextCancelledBeforeItBeginsReturnsNilAndTakesNothing() async {
        let (queue, _) = makeQueue()
        queue.push(.data(bytes(3)))
        let cancelled = Task { () -> StreamMessage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.next()
        }
        #expect(await cancelled.value == nil)
        let later = Task { await queue.next() }
        #expect(await later.value == .data(bytes(3)))
    }

    @Test func aNextAfterACancelledOneStillGetsQueuedMessages() async {
        let (queue, _) = makeQueue()
        let first = Task { await queue.next() }
        await waitUntilParked(queue)
        first.cancel()
        #expect(await first.value == nil)
        queue.push(.data(bytes(3)))
        let second = Task { await queue.next() }
        #expect(await second.value == .data(bytes(3)))
    }
}
