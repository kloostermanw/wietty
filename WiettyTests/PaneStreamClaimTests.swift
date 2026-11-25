import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// One ordered record of what happened during a claim: the messages each viewer
/// was sent and the hooks the hub called, in the order they happened. Lock
/// guarded: the hub calls sinks and hooks from its own queue.
private final class Timeline: @unchecked Sendable {
    enum Event: Equatable {
        case message(String, StreamMessage)
        case claimed(String, TerminalSize)
        case repaintTaken
    }

    private let lock = NSLock()
    private var storage: [Event] = []
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ event: Event) { lock.lock(); storage.append(event); lock.unlock() }

    func sink(_ viewer: String) -> @Sendable (StreamMessage) -> Void {
        { [self] message in add(.message(viewer, message)) }
    }

    /// What one viewer was sent, in order.
    func messages(of viewer: String) -> [StreamMessage] {
        events.compactMap { event in
            if case let .message(name, message) = event, name == viewer { return message }
            return nil
        }
    }

    /// Where an event first happened, or nil.
    func index(of event: Event) -> Int? { events.firstIndex(of: event) }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func isData(_ message: StreamMessage) -> Bool {
    if case .data = message { return true }
    return false
}

private func dataBytes(_ messages: [StreamMessage]) -> [UInt8] {
    messages.flatMap { message -> [UInt8] in
        if case let .data(payload) = message { return payload }
        return []
    }
}

/// A viewer saying "I am active, this is my grid", and the hub telling every viewer
/// whose claim it was.
@Suite struct PaneStreamClaimTests {
    private static let grid = TerminalSize(cols: 100, rows: 30)

    /// Leaves `payload` in the buffer of session `gt:1`, for a claim to take.
    ///
    /// A write into a quiet session goes out at once on its own flush, queued ahead
    /// of any claim, and would leave the claim nothing to take. So a primer byte
    /// `p` is written and flushed first, which makes the session not quiet for the
    /// next 8 ms, and `payload` is written straight after. The quiet flush count
    /// proves it: were the write quiet after all, the test fails here rather than
    /// passing on an empty take.
    private func writeOutstanding(_ hub: PaneStreamHub, _ payload: [UInt8]) throws {
        hub.write(session: "gt:1", bytes: bytes("p"))
        hub.flush()
        let quiet = hub.quietFlushes(session: "gt:1")
        hub.write(session: "gt:1", bytes: payload)
        try #require(hub.quietFlushes(session: "gt:1") == quiet, "the write was quiet")
    }

    /// A hub whose repaint and claim hooks are recorded on `timeline`. Its clock
    /// paces every claim, so claims sent back to back are each handled at once: the
    /// hold on claims has its own suite, `PaneStreamClaimPaceTests`.
    private func hub(_ timeline: Timeline) -> PaneStreamHub {
        let hub = PaneStreamHub(claimClock: ClaimTimers.paced())
        hub.onRepaint = { _ in
            timeline.add(.repaintTaken)
            return (size: Self.grid, frame: bytes("SCREEN"))
        }
        hub.onClaim = { session, size in timeline.add(.claimed(session, size)) }
        return hub
    }

    /// A new grid: the pty and the model are resized first, and only then is the
    /// repaint taken. The bytes accepted before it go to every viewer, then every
    /// viewer is told the grid, `own` true for the claimant alone, then the
    /// viewers that asked for repaints get the screen.
    @Test func aClaimForANewGridResizesFirstAndTellsEveryViewerWhoseItWas() throws {
        let timeline = Timeline()
        let hub = hub(timeline)
        let claimant = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("reflowing"))
        hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("repainted"))
        hub.waitForPendingDeliveries()
        try writeOutstanding(hub, bytes("ab"))

        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()

        let claimed = try #require(timeline.index(of: .claimed("gt:1", Self.grid)))
        let painted = try #require(timeline.index(of: .repaintTaken))
        let firstResize = try #require(timeline.events.firstIndex {
            if case .message(_, .resize) = $0 { return true }
            return false
        })
        #expect(claimed < painted)
        #expect(claimed < firstResize)

        let screen = StreamMessage.repaint(TerminalPaint.reset + bytes("SCREEN"))
        for (viewer, own, repaints) in [("claimant", true, true), ("reflowing", false, false),
                                        ("repainted", false, true)] {
            let messages = timeline.messages(of: viewer)
            #expect(dataBytes(messages) == bytes("pab"), "\(viewer)")
            // The claim's own take, as one message just ahead of the grid.
            let tail: [StreamMessage] = [.data(bytes("ab")), .resize(cols: 100, rows: 30, own: own)]
                + (repaints ? [screen] : [])
            #expect(Array(messages.suffix(tail.count)) == tail, "\(viewer)")
            #expect(messages.dropLast(tail.count).allSatisfy(isData), "\(viewer)")
        }
    }

    /// The grid in force already: nothing is resized and nobody else hears of it,
    /// but the claimant is still answered, so it knows the claim was taken.
    @Test func aClaimForTheGridInForceIsAnsweredToTheClaimantAlone() {
        let timeline = Timeline()
        let hub = hub(timeline)
        let claimant = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("claimant"))
        let other = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("other"))
        hub.claim(connectionId: other, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        let before = timeline.events.count

        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()

        #expect(Array(timeline.events.dropFirst(before))
                == [.message("claimant", .resize(cols: 100, rows: 30, own: true))])
    }

    /// Every claim is answered once to its claimant, in order, whether it moved
    /// the grid or not.
    @Test func everyClaimIsAnsweredExactlyOnceToItsClaimant() {
        let timeline = Timeline()
        let hub = hub(timeline)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.claim(connectionId: claimant, cols: 90, rows: 20)
        hub.waitForPendingDeliveries()

        // A viewer that reflows asks for no repaint, so each answer names the
        // claimed grid itself.
        #expect(timeline.messages(of: "claimant") == [.resize(cols: 100, rows: 30, own: true),
                                                      .resize(cols: 100, rows: 30, own: true),
                                                      .resize(cols: 90, rows: 20, own: true)])
        #expect(timeline.events.filter { if case .claimed = $0 { true } else { false } }
                == [.claimed("gt:1", Self.grid), .claimed("gt:1", TerminalSize(cols: 90, rows: 20))])
    }

    /// Bytes accepted before the claim is handled reach the claimant before its
    /// answer, and bytes accepted after it reach the claimant after it.
    @Test func outputKeepsItsPlaceAroundAClaim() throws {
        for equal in [false, true] {
            let timeline = Timeline()
            let hub = PaneStreamHub()
            let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
            let other = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
            if equal { hub.claim(connectionId: other, cols: 100, rows: 30) }
            hub.waitForPendingDeliveries()
            try writeOutstanding(hub, bytes("before"))
            hub.claim(connectionId: claimant, cols: 100, rows: 30)
            hub.waitForPendingDeliveries()
            hub.write(session: "gt:1", bytes: bytes("after"))
            hub.flush()

            let messages = timeline.messages(of: "claimant")
            let answer = messages.firstIndex(of: .resize(cols: 100, rows: 30, own: true))
            #expect(answer != nil, "equal \(equal)")
            guard let answer else { continue }
            #expect(dataBytes(Array(messages[..<answer])) == bytes("pbefore"), "equal \(equal)")
            #expect(answer > 0 && messages[answer - 1] == .data(bytes("before")), "equal \(equal)")
            #expect(dataBytes(Array(messages[(answer + 1)...])) == bytes("after"), "equal \(equal)")
            #expect(dataBytes(timeline.messages(of: "other")) == bytes("pbeforeafter"),
                    "equal \(equal)")
        }
    }

    /// The record holds the grid the viewers were told, which is the model's when
    /// it differs from the claim, so a later claim of that grid is the grid in
    /// force and moves nothing.
    @Test func theRecordHoldsTheGridTheViewersWereTold() {
        let timeline = Timeline()
        let hub = PaneStreamHub(claimClock: ClaimTimers.paced())
        hub.onRepaint = { _ in (size: TerminalSize(cols: 90, rows: 20), frame: bytes("SCREEN")) }
        hub.onClaim = { session, size in timeline.add(.claimed(session, size)) }
        let claimant = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "other") == [.resize(cols: 90, rows: 20, own: false)])
        let before = timeline.events.count

        hub.claim(connectionId: claimant, cols: 90, rows: 20)
        hub.waitForPendingDeliveries()

        #expect(Array(timeline.events.dropFirst(before))
                == [.message("claimant", .resize(cols: 90, rows: 20, own: true))])
    }

    /// The hub accepts exactly the grids the codec lets through as a `resize`, so
    /// the bounds kept in two places cannot drift apart unnoticed.
    @Test func theHubAcceptsExactlyTheGridsTheCodecDecodes() {
        for (cols, rows) in [(1, 1), (10_000, 10_000), (0, 24), (80, 0), (10_001, 24), (80, 10_001)] {
            let text = #"{"cols":\#(cols),"own":false,"rows":\#(rows),"type":"resize"}"#
            let decoded = StreamCodec.message(from: .text(text)) != nil
            let timeline = Timeline()
            let hub = PaneStreamHub()
            let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
            hub.claim(connectionId: claimant, cols: cols, rows: rows)
            hub.waitForPendingDeliveries()
            let answered = !timeline.messages(of: "claimant").isEmpty
            #expect(decoded == answered, "\(cols)x\(rows): codec \(decoded), hub \(answered)")
        }
        // Both ways, or the comparison above proves nothing.
        #expect(StreamCodec.message(from: .text(#"{"cols":1,"own":false,"rows":1,"type":"resize"}"#)) != nil)
        #expect(StreamCodec.message(from: .text(#"{"cols":0,"own":false,"rows":1,"type":"resize"}"#)) == nil)
    }

    /// A viewer that has gone, or never was, claims nothing.
    @Test func aClaimFromADetachedOrUnknownViewerDoesNothing() {
        let timeline = Timeline()
        let hub = hub(timeline)
        let gone = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("gone"))
        hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("other"))
        hub.detach(connectionId: gone)

        hub.claim(connectionId: gone, cols: 100, rows: 30)
        hub.claim(connectionId: UUID(), cols: 100, rows: 30)
        hub.waitForPendingDeliveries()

        #expect(timeline.events.isEmpty)
    }

    /// A grid outside what the protocol allows is not a claim.
    @Test func aClaimOutsideTheRangeIsIgnored() {
        let timeline = Timeline()
        let hub = hub(timeline)
        let claimant = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("claimant"))
        for (cols, rows) in [(0, 30), (100, 0), (10_001, 30), (100, 10_001), (-1, -1)] {
            hub.claim(connectionId: claimant, cols: cols, rows: rows)
        }
        hub.waitForPendingDeliveries()
        #expect(timeline.events.isEmpty)

        hub.claim(connectionId: claimant, cols: 10_000, rows: 1)
        hub.waitForPendingDeliveries()
        #expect(timeline.events.contains(.claimed("gt:1", TerminalSize(cols: 10_000, rows: 1))))
    }
}

/// A claim through the stack as the app wires it: the hub's `onClaim` reaches the
/// resizer `GhosttyService` registered, which resizes the real pty and the model.
@MainActor
@Suite struct PaneStreamClaimWiringTests {
    /// The main actor plays no part: this test blocks it on a semaphore without
    /// yielding, so a claim that needed it could only time out.
    @Test func aClaimIsHandledWhileTheMainActorIsBlocked() throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let shared = try #require(stack.ghosttyService?.shared)
        shared.note(live: ["gt:blocked"])
        let resized = DispatchSemaphore(value: 0)
        let answered = DispatchSemaphore(value: 0)
        shared.register(resizer: { size in
            if size == TerminalSize(cols: 77, rows: 22) { resized.signal() }
        }, for: "gt:blocked")
        let hub = stack.hub
        let claimant = hub.attach(session: "gt:blocked", resize: .reflow) { message in
            if message == .resize(cols: 77, rows: 22, own: true) { answered.signal() }
        }
        DispatchQueue.global().async { hub.claim(connectionId: claimant, cols: 77, rows: 22) }
        #expect(resized.wait(timeout: .now() + 3) == .success)
        #expect(answered.wait(timeout: .now() + 3) == .success)
    }

    /// A claim reaches the child: `stty size` in it prints the claimed grid, and
    /// the claimant's answer names it, which it takes from the model's repaint.
    @Test func aClaimReachesTheRealPtyAndTheModel() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let probe = TestScratch.root.appendingPathComponent("claim-\(UUID().uuidString)").path
        let handle = try await stack.service.open(
            folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
            command: "trap 'stty size > \(probe)' WINCH; while true; do sleep 0.2; done",
            badge: nil)
        let answers = Answers()
        let claimant = stack.hub.attach(session: handle.sessionId, resize: .repaint) { answers.add($0) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: probe) == false)

        stack.hub.claim(connectionId: claimant, cols: 111, rows: 41)
        try await waitUntil {
            (try? String(contentsOfFile: probe, encoding: .utf8))?.contains("41 111") ?? false
        }
        stack.hub.waitForPendingDeliveries()
        #expect(answers.messages.contains(.resize(cols: 111, rows: 41, own: true)))
        let model = try #require(stack.ghosttyService?.screenModel(for: handle.sessionId))
        #expect(model.repaintFrame()?.size == TerminalSize(cols: 111, rows: 41))
    }

    /// The resizer goes wherever the writer goes: a reaped child and a closed row
    /// leave nothing to resize.
    @Test func theResizerIsRemovedWithTheWriter() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let service = try #require(stack.ghosttyService)
        let shared = service.shared

        let exiting = try await service.open(folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
                                             command: "exit 0", badge: nil)
        let staying = try await service.open(folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
                                             command: "sleep 5", badge: nil)
        #expect(shared.resizer(for: staying.sessionId) != nil)
        try await waitUntil { shared.writer(for: exiting.sessionId) == nil }
        #expect(shared.resizer(for: exiting.sessionId) == nil)

        try await stack.service.close(sessionId: staying.sessionId)
        #expect(shared.writer(for: staying.sessionId) == nil)
        #expect(shared.resizer(for: staying.sessionId) == nil)

        let last = try await service.open(folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
                                          command: "sleep 5", badge: nil)
        #expect(shared.resizer(for: last.sessionId) != nil)
        service.closeAll()
        #expect(shared.resizer(for: last.sessionId) == nil)
    }

    private func waitUntil(timeout: Duration = .seconds(6),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamMessage] = []
    func add(_ message: StreamMessage) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// A clock and timers the test drives, for the hub's hold on claims: no claim waits
/// on real time, and a timer fires only when the test fires it.
final class ClaimTimers: @unchecked Sendable {
    private struct Scheduled {
        let delay: UInt64
        let queue: DispatchQueue
        let work: @Sendable () -> Void
        var cancelled = false
    }

    private let lock = NSLock()
    private var time: UInt64 = 1_000_000_000
    private var scheduled: [Scheduled] = []

    var now: UInt64 { lock.withLock { time } }
    func advance(milliseconds: UInt64) { lock.withLock { time += milliseconds * 1_000_000 } }

    var clock: PaneStreamHub.ClaimClock { { [self] in now } }
    var scheduler: PaneStreamHub.ClaimScheduler {
        { [self] delay, queue, work in
            let index = lock.withLock {
                scheduled.append(Scheduled(delay: delay, queue: queue, work: work))
                return scheduled.count - 1
            }
            return { [self] in lock.withLock { scheduled[index].cancelled = true } }
        }
    }

    /// How many timers the hub has asked for.
    var count: Int { lock.withLock { scheduled.count } }
    func delay(_ index: Int) -> UInt64 { lock.withLock { scheduled[index].delay } }
    func isCancelled(_ index: Int) -> Bool { lock.withLock { scheduled[index].cancelled } }

    /// Fires timer `index` the way its dispatch source would: on its queue, and not
    /// at all once cancelled. Whether it fired. The work runs asynchronously, so the
    /// caller waits for the hub's deliveries afterwards.
    @discardableResult
    func fire(_ index: Int) -> Bool {
        let timer = lock.withLock { scheduled[index] }
        guard !timer.cancelled else { return false }
        timer.queue.async(execute: timer.work)
        return true
    }

    /// Runs timer `index`'s work on its queue even if it was cancelled: what a timer
    /// that fired at the instant it was cancelled would do.
    func runAnyway(_ index: Int) {
        let timer = lock.withLock { scheduled[index] }
        timer.queue.async(execute: timer.work)
    }

    func hub(startTimer: Bool = false) -> PaneStreamHub {
        PaneStreamHub(startTimer: startTimer, claimClock: clock, claimScheduler: scheduler)
    }

    /// A clock that moves on by the hub's whole interval every time it is read, so
    /// every claim is paced and none is ever held: for tests about something other
    /// than the hold that send claims back to back.
    static func paced() -> PaneStreamHub.ClaimClock {
        let timers = ClaimTimers()
        return {
            timers.advance(milliseconds: PaneStreamHub.claimInterval / 1_000_000)
            return timers.now
        }
    }
}

/// The hub holds each viewer's claims to one per 50 ms: a sooner claim is held, a
/// later one replaces it, and every claim is still answered once, in order.
@Suite struct PaneStreamClaimPaceTests {
    private static let small = TerminalSize(cols: 90, rows: 20)
    private static let large = TerminalSize(cols: 100, rows: 30)

    private func own(_ size: TerminalSize) -> StreamMessage {
        .resize(cols: size.cols, rows: size.rows, own: true)
    }

    private func other(_ size: TerminalSize) -> StreamMessage {
        .resize(cols: size.cols, rows: size.rows, own: false)
    }

    /// A hub on `timers` whose claim hook is recorded on `timeline`. No repaint
    /// hook, so each answer names the grid claimed.
    private func hub(_ timeline: Timeline, _ timers: ClaimTimers) -> PaneStreamHub {
        let hub = timers.hub()
        hub.onClaim = { session, size in timeline.add(.claimed(session, size)) }
        return hub
    }

    private func claims(_ timeline: Timeline) -> [TerminalSize] {
        timeline.events.compactMap { event in
            if case let .claimed(_, size) = event { return size }
            return nil
        }
    }

    private func claim(_ hub: PaneStreamHub, _ id: UUID, _ size: TerminalSize) {
        hub.claim(connectionId: id, cols: size.cols, rows: size.rows)
    }

    /// Claims 50 ms apart, the pace the pane keeps, are each handled at once,
    /// exactly as before: no timer, one reflow and one round of `resize` each.
    @Test func pacedClaimsAreHandledAtOnce() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))

        for size in [Self.large, Self.small, Self.large] {
            claim(hub, claimant, size)
            hub.waitForPendingDeliveries()
            timers.advance(milliseconds: 50)
        }

        #expect(timers.count == 0)
        #expect(claims(timeline) == [Self.large, Self.small, Self.large])
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small), own(Self.large)])
        #expect(timeline.messages(of: "other") == [other(Self.large), other(Self.small), other(Self.large)])
    }

    /// A claim 49 ms after the last one handled is held, for the 1 ms that is left.
    @Test func aClaimInsideTheIntervalIsHeldForWhatIsLeftOfIt() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        claim(hub, claimant, Self.large)
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 49)

        claim(hub, claimant, Self.small)
        hub.waitForPendingDeliveries()

        #expect(timeline.messages(of: "claimant") == [own(Self.large)])
        #expect(timers.count == 1)
        #expect(timers.delay(0) == 1_000_000)
        timers.advance(milliseconds: 1)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small)])
        #expect(claims(timeline) == [Self.large, Self.small])
    }

    /// A burst of claims: the first is handled at once, the rest wait for one timer,
    /// and then every one of them is answered with `own` true, in order. Those that
    /// were replaced carry the grid in force and move nothing; the last is handled
    /// as any claim. So at most two reflows, and the other viewers hear of two grids.
    @Test func aBurstIsAnsweredInFullWithAtMostTwoReflows() {
        for count in [2, 3, 20] {
            let timeline = Timeline()
            let timers = ClaimTimers()
            let hub = hub(timeline, timers)
            let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
            hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
            // Large first, alternating between, ending on small: the last claim
            // is for a grid other than the one in force.
            let sizes = [Self.large] + (1..<count - 1).map { $0 % 2 == 1 ? Self.small : Self.large }
                + [Self.small]
            let last = Self.small

            for size in sizes { claim(hub, claimant, size) }
            hub.waitForPendingDeliveries()
            #expect(timeline.messages(of: "claimant") == [own(sizes[0])], "\(count)")
            #expect(timers.count == 1, "\(count)")
            #expect(timers.delay(0) == PaneStreamHub.claimInterval, "\(count)")

            timers.advance(milliseconds: 50)
            #expect(timers.fire(0))
            hub.waitForPendingDeliveries()

            let expected = [own(sizes[0])] + Array(repeating: own(sizes[0]), count: count - 2) + [own(last)]
            #expect(timeline.messages(of: "claimant") == expected, "\(count)")
            #expect(claims(timeline) == [sizes[0], last], "\(count)")
            #expect(timeline.messages(of: "other") == [other(sizes[0]), other(last)], "\(count)")
            #expect(timers.count == 1, "\(count)")
        }
    }

    /// A burst ending on the grid in force: the held claim is answered to the
    /// claimant alone, like any claim for the grid in force, so one reflow in all.
    @Test func aBurstEndingOnTheGridInForceReflowsOnce() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))

        for size in [Self.large, Self.small, Self.large, Self.small, Self.large] { claim(hub, claimant, size) }
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 50)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()

        #expect(timeline.messages(of: "claimant") == Array(repeating: own(Self.large), count: 5))
        #expect(claims(timeline) == [Self.large])
        #expect(timeline.messages(of: "other") == [other(Self.large)])
    }

    /// The bytes accepted before the held claim is handled reach the claimant ahead
    /// of that claim's answer, as for any claim.
    @Test func aHeldClaimKeepsOutputInItsPlace() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        claim(hub, claimant, Self.large)
        claim(hub, claimant, Self.small)
        hub.waitForPendingDeliveries()
        hub.write(session: "gt:1", bytes: Array("before".utf8))
        timers.advance(milliseconds: 50)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        hub.write(session: "gt:1", bytes: Array("after".utf8))
        hub.flush()

        let messages = timeline.messages(of: "claimant")
        let answer = messages.firstIndex(of: own(Self.small))
        #expect(answer != nil)
        guard let answer else { return }
        #expect(dataBytes(Array(messages[..<answer])) == Array("before".utf8))
        #expect(dataBytes(Array(messages[(answer + 1)...])) == Array("after".utf8))
    }

    /// A replaced claim's answer never overtakes a byte accepted before it: output
    /// written after the claims and before the release reaches a queued claimant,
    /// and the other viewers, ahead of the first answer the release sends.
    @Test func aReplacedClaimsAnswerFollowsTheBytesBeforeIt() throws {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
        let third = TerminalSize(cols: 80, rows: 24)
        claim(hub, claimant, Self.large)
        claim(hub, claimant, Self.small)
        claim(hub, claimant, third)
        hub.waitForPendingDeliveries()

        // Left in the buffer, as `PaneStreamClaimTests.writeOutstanding` does: a
        // primer flushed first makes the session not quiet, so the payload is not
        // sent on a flush of its own and only the release can take it.
        hub.write(session: "gt:1", bytes: Array("p".utf8))
        hub.flush()
        let quiet = hub.quietFlushes(session: "gt:1")
        hub.write(session: "gt:1", bytes: Array("between".utf8))
        try #require(hub.quietFlushes(session: "gt:1") == quiet, "the write was quiet")
        timers.advance(milliseconds: 50)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()

        #expect(timeline.messages(of: "claimant") == [own(Self.large), .data(Array("p".utf8)),
                                                      .data(Array("between".utf8)),
                                                      own(Self.large), own(third)])
        #expect(timeline.messages(of: "other") == [other(Self.large), .data(Array("p".utf8)),
                                                   .data(Array("between".utf8)), other(third)])
    }

    /// A claim that arrives after the interval is over while one is still held
    /// (its timer due but not yet run) replaces the held claim rather than being
    /// handled at once, which would overtake it. No second timer is started.
    @Test func aClaimAfterTheIntervalReplacesAClaimStillHeld() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        let third = TerminalSize(cols: 80, rows: 24)
        claim(hub, claimant, Self.large)
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 10)
        claim(hub, claimant, Self.small)
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 60)
        claim(hub, claimant, third)
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large)])
        #expect(timers.count == 1)

        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        // One replaced claim, answered with the grid in force, then the held one.
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.large), own(third)])
        #expect(claims(timeline) == [Self.large, third])
        #expect(timers.count == 1)
    }

    /// A timer that runs late does not push the viewer's next interval back: the
    /// held claim counts as handled when it was due, not when it ran.
    @Test func aLateTimerCountsTheHeldClaimAsHandledWhenItWasDue() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        claim(hub, claimant, Self.large)
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 10)
        claim(hub, claimant, Self.small)
        hub.waitForPendingDeliveries()
        // Due 50 ms after the first claim; it runs 30 ms late.
        timers.advance(milliseconds: 70)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small)])

        // 100 ms after the first claim: 50 after the held one was due, so handled
        // at once, though only 20 ms after its timer ran.
        timers.advance(milliseconds: 20)
        claim(hub, claimant, Self.large)
        hub.waitForPendingDeliveries()
        #expect(timers.count == 1)
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small), own(Self.large)])
    }

    /// A timer that runs early leaves the last handled time (when the held claim was
    /// due) ahead of the clock. A claim then counts as 0 ms after it, so it is held
    /// for the whole interval, rather than the difference wrapping around and the
    /// claim being handled at once.
    @Test func aClaimBeforeTheLastHandledTimeIsHeld() throws {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        claim(hub, claimant, Self.large)
        claim(hub, claimant, Self.small)
        hub.waitForPendingDeliveries()
        // Fired with the clock not moved: 50 ms early.
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small)])

        claim(hub, claimant, Self.large)
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small)])
        try #require(timers.count == 2)
        #expect(timers.delay(1) == PaneStreamHub.claimInterval)
    }

    /// The timer fires once: handling the held claim schedules nothing, and its work
    /// run a second time finds nothing held. The next claim inside the interval
    /// after that is held again, on a timer of its own.
    @Test func theTimerFiresOnce() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        for size in [Self.large, Self.small, Self.large, Self.small] { claim(hub, claimant, size) }
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 50)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        let answered = timeline.messages(of: "claimant")
        #expect(answered.count == 4)

        timers.runAnyway(0)
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == answered)
        #expect(timers.count == 1)

        // Handled when the timer fired, so a claim now is inside the interval again.
        claim(hub, claimant, Self.large)
        hub.waitForPendingDeliveries()
        #expect(timers.count == 2)
        #expect(timeline.messages(of: "claimant") == answered)
    }

    /// Two viewers bursting at once are held each on its own: each one's first
    /// claim is handled at once, each gets a timer, and each is answered in full.
    @Test func twoViewersAreHeldIndependently() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let first = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("first"))
        let second = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("second"))
        claim(hub, first, Self.large)
        claim(hub, second, Self.small)
        claim(hub, first, Self.small)
        claim(hub, second, Self.large)
        claim(hub, first, Self.large)
        hub.waitForPendingDeliveries()

        #expect(claims(timeline) == [Self.large, Self.small])
        #expect(timers.count == 2)
        #expect(timeline.messages(of: "first") == [own(Self.large), other(Self.small)])
        #expect(timeline.messages(of: "second") == [other(Self.large), own(Self.small)])

        timers.advance(milliseconds: 50)
        #expect(timers.fire(1))
        hub.waitForPendingDeliveries()
        // The second's held claim moves the grid back to large.
        #expect(timeline.messages(of: "second") == [other(Self.large), own(Self.small), own(Self.large)])
        #expect(timeline.messages(of: "first") == [own(Self.large), other(Self.small), other(Self.large)])

        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        // The first's replaced claim is answered with the grid in force (large), and
        // its held claim (large) is the grid in force too.
        #expect(timeline.messages(of: "first")
                == [own(Self.large), other(Self.small), other(Self.large), own(Self.large), own(Self.large)])
        #expect(claims(timeline) == [Self.large, Self.small, Self.large])
    }

    /// A local viewer's claims are held by the same rule.
    @Test func aLocalViewersClaimsAreHeldToo() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        defer { hub.stop() }
        let claimant = hub.attachLocal(session: "gt:1", resize: .reflow, write: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
        for size in [Self.large, Self.small, Self.large, Self.small] { claim(hub, claimant, size) }
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large)])
        #expect(timers.count == 1)

        timers.advance(milliseconds: 50)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant")
                == [own(Self.large), own(Self.large), own(Self.large), own(Self.small)])
        #expect(claims(timeline) == [Self.large, Self.small])
        #expect(timeline.messages(of: "other") == [other(Self.large), other(Self.small)])
    }

    /// A grid out of bounds is no claim, so it neither starts a hold nor replaces
    /// a held claim, and is not counted among those answered.
    @Test func theBoundsApplyBeforeTheHold() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        claim(hub, claimant, Self.large)
        hub.claim(connectionId: claimant, cols: 0, rows: 20)
        hub.waitForPendingDeliveries()
        #expect(timers.count == 0)

        claim(hub, claimant, Self.small)
        hub.claim(connectionId: claimant, cols: 10_001, rows: 20)
        hub.waitForPendingDeliveries()
        timers.advance(milliseconds: 50)
        #expect(timers.fire(0))
        hub.waitForPendingDeliveries()
        #expect(timeline.messages(of: "claimant") == [own(Self.large), own(Self.small)])
    }

    /// Detach drops the held claim and cancels its timer: nothing reaches the
    /// viewer that is gone or anyone else, even from a timer that fired regardless.
    @Test func detachDropsTheHeldClaim() {
        for local in [false, true] {
            let timeline = Timeline()
            let timers = ClaimTimers()
            let hub = hub(timeline, timers)
            defer { hub.stop() }
            let claimant = local
                ? hub.attachLocal(session: "gt:1", resize: .reflow, write: timeline.sink("claimant"))
                : hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
            hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
            for size in [Self.large, Self.small, Self.large, Self.small] { claim(hub, claimant, size) }
            hub.waitForPendingDeliveries()
            let before = timeline.events

            hub.detach(connectionId: claimant)
            #expect(timers.isCancelled(0), "local \(local)")
            timers.runAnyway(0)
            hub.waitForPendingDeliveries()
            #expect(timeline.events == before, "local \(local)")
        }
    }

    /// The end of the session drops the held claim and its timer: the claimant's
    /// `ended` is the last it hears.
    @Test func theSessionsEndDropsTheHeldClaim() {
        for local in [false, true] {
            let timeline = Timeline()
            let timers = ClaimTimers()
            let hub = hub(timeline, timers)
            defer { hub.stop() }
            let claimant = local
                ? hub.attachLocal(session: "gt:1", resize: .reflow, write: timeline.sink("claimant"))
                : hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
            for size in [Self.large, Self.small, Self.large] { claim(hub, claimant, size) }
            hub.waitForPendingDeliveries()

            hub.endViewers(ofSession: "gt:1")
            hub.waitForPendingDeliveries()
            #expect(timers.isCancelled(0), "local \(local)")
            timers.runAnyway(0)
            hub.waitForPendingDeliveries()
            #expect(timeline.messages(of: "claimant") == [own(Self.large), .ended], "local \(local)")
            #expect(claims(timeline) == [Self.large], "local \(local)")
        }
    }

    /// `stop()` drops every held claim and cancels every timer.
    @Test func stopDropsEveryHeldClaim() {
        let timeline = Timeline()
        let timers = ClaimTimers()
        let hub = hub(timeline, timers)
        let first = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("first"))
        let second = hub.attachLocal(session: "gt:2", resize: .reflow, write: timeline.sink("second"))
        for size in [Self.large, Self.small] {
            claim(hub, first, size)
            claim(hub, second, size)
        }
        hub.waitForPendingDeliveries()
        #expect(timers.count == 2)
        let before = timeline.events

        hub.stop()
        #expect(timers.isCancelled(0))
        #expect(timers.isCancelled(1))
        timers.runAnyway(0)
        timers.runAnyway(1)
        hub.waitForPendingDeliveries()
        #expect(timeline.events == before)
    }

    /// A hub that goes away cancels the timer of a claim it still held.
    @Test func noTimerOutlivesTheHub() {
        let timers = ClaimTimers()
        do {
            let hub = timers.hub()
            let claimant = hub.attach(session: "gt:1", resize: .reflow) { _ in }
            hub.claim(connectionId: claimant, cols: 100, rows: 30)
            hub.claim(connectionId: claimant, cols: 90, rows: 20)
            hub.waitForPendingDeliveries()
        }
        #expect(timers.count == 1)
        #expect(timers.isCancelled(0))
    }
}
