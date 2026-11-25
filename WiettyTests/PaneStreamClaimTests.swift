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

    /// A hub whose repaint and claim hooks are recorded on `timeline`.
    private func hub(_ timeline: Timeline) -> PaneStreamHub {
        let hub = PaneStreamHub()
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
        hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("other"))
        hub.noteSize(session: "gt:1", Self.grid)
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
            hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
            if equal { hub.noteSize(session: "gt:1", Self.grid) }
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

    /// A grid the surface reported, overtaken by a claim before its resize was
    /// delivered, is not announced: it is no longer the grid in force, and telling
    /// it would leave the viewers on a grid the pty is not.
    @Test func aReportedGridOvertakenByAClaimIsNotAnnounced() {
        let timeline = Timeline()
        let hub = PaneStreamHub()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // A claim on another session whose resizer holds the delivery queue, so
        // the claim and the report below are both queued before either runs.
        hub.onClaim = { session, size in
            timeline.add(.claimed(session, size))
            if session == "gt:block" { entered.signal(); release.wait() }
        }
        let blocker = hub.attach(session: "gt:block", resize: .reflow) { _ in }
        let claimant = hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .reflow, onMessage: timeline.sink("other"))
        hub.claim(connectionId: blocker, cols: 50, rows: 10)
        #expect(entered.wait(timeout: .now() + 3) == .success)

        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.noteSize(session: "gt:1", TerminalSize(cols: 80, rows: 24))
        release.signal()
        hub.waitForPendingDeliveries()

        #expect(timeline.messages(of: "claimant") == [.resize(cols: 100, rows: 30, own: true)])
        #expect(timeline.messages(of: "other") == [.resize(cols: 100, rows: 30, own: false)])
    }

    /// The record holds the grid the viewers were told, which is the model's when
    /// it differs from the claim, so a later claim of that grid is the grid in
    /// force and moves nothing.
    @Test func theRecordHoldsTheGridTheViewersWereTold() {
        let timeline = Timeline()
        let hub = PaneStreamHub()
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

    /// One record of the grid in force, whoever set it: the surface reporting the
    /// grid a claim already set moves nothing.
    @Test func notingTheGridAClaimSetSendsNothing() {
        let timeline = Timeline()
        let hub = hub(timeline)
        let claimant = hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("claimant"))
        hub.attach(session: "gt:1", resize: .repaint, onMessage: timeline.sink("other"))
        hub.claim(connectionId: claimant, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        let before = timeline.events.count

        hub.noteSize(session: "gt:1", Self.grid)
        hub.waitForPendingDeliveries()

        #expect(timeline.events.count == before)
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
        defer { stack.ghosttyService?.closeAll() }
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
        defer { stack.ghosttyService?.closeAll() }
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
        let service = try #require(stack.ghosttyService)
        defer { service.closeAll() }
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
