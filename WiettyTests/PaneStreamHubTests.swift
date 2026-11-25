import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// Everything a viewer was sent, in order. Lock guarded: the hub calls a sink from
/// its own queue.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamMessage] = []
    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return storage }
    func receive(_ message: StreamMessage) { lock.lock(); storage.append(message); lock.unlock() }

    /// The payloads of the `data` messages, joined. For the tests that care what
    /// arrived and not how it was batched: a write into a quiet session is
    /// delivered at once, so how many `data` messages a run of writes becomes
    /// depends on timing.
    var dataBytes: [UInt8] {
        messages.flatMap { message -> [UInt8] in
            if case let .data(bytes) = message { return bytes }
            return []
        }
    }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

@Suite struct PaneStreamHubTests {
    @Test func deliversOutputToASubscriber() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        hub.write(session: "%12", bytes: bytes("he"))
        hub.write(session: "%12", bytes: bytes("llo"))
        hub.flush()
        #expect(sink.dataBytes == bytes("hello"))
    }

    @Test func doesNotDeliverOutputForAnotherPane() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        hub.write(session: "%99", bytes: bytes("nope"))
        hub.flush()
        #expect(sink.messages.isEmpty)
    }

    @Test func deliversTheSamePaneToEveryViewer() {
        let hub = PaneStreamHub()
        let first = Sink()
        let second = Sink()
        hub.attach(session: "%12", resize: .repaint) { first.receive($0) }
        hub.attach(session: "%12", resize: .reflow) { second.receive($0) }
        hub.write(session: "%12", bytes: bytes("x"))
        hub.flush()
        #expect(first.messages == [.data(bytes("x"))])
        #expect(second.messages == [.data(bytes("x"))])
    }

    /// The bytes on the wire are the child's own: an invalid sequence is not
    /// replaced, and a character cut between two reads is not held back or joined.
    /// A viewer's terminal decodes them, as it decodes them from any pty.
    @Test func bytesArriveExactlyAsTheyWereWritten() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        // 0xC3 0x28 is not UTF-8: a lead byte and then no continuation.
        hub.write(session: "%12", bytes: [0xC3, 0x28])
        hub.flush()
        // The three bytes of U+65E5, cut after the first.
        hub.write(session: "%12", bytes: [0x61, 0xE6])
        hub.flush()
        hub.write(session: "%12", bytes: [0x97, 0xA5])
        hub.flush()
        #expect(sink.messages == [.data([0xC3, 0x28]), .data([0x61, 0xE6]), .data([0x97, 0xA5])])
    }

    @Test func emitsNothingWhenThereIsNoBufferedOutput() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        hub.flush()
        #expect(sink.messages.isEmpty)
    }

    /// A session's viewers are ended by naming that session, which is the only
    /// shape there is: a terminal belongs to no server and no workspace object, so
    /// whatever reaps one names exactly the session that ended.
    @Test func endsEveryViewerOfOneSessionAndNobodyElses() {
        let hub = PaneStreamHub()
        let doomed = Sink()
        let alsoWatching = Sink()
        let survivor = Sink()
        hub.attach(session: "gt:1", resize: .repaint) { doomed.receive($0) }
        hub.attach(session: "gt:1", resize: .reflow) { alsoWatching.receive($0) }
        hub.attach(session: "gt:2", resize: .repaint) { survivor.receive($0) }

        hub.endViewers(ofSession: "gt:1")
        hub.waitForPendingDeliveries()

        #expect(doomed.messages == [.ended])
        #expect(alsoWatching.messages == [.ended])
        #expect(survivor.messages.isEmpty)
        // The bytes of a session that has ended reach nobody: its viewers are gone
        // and its buffer went with them.
        hub.write(session: "gt:1", bytes: bytes("late"))
        hub.flush()
        #expect(doomed.messages == [.ended])
    }

    /// The last bytes come before the ending, byte exact.
    @Test func anEndingDeliversWhatIsBufferedFirst() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "gt:1", resize: .repaint) { sink.receive($0) }
        hub.waitForPendingDeliveries()
        hub.write(session: "gt:1", bytes: [0x62, 0xE6])
        hub.endViewers(ofSession: "gt:1")
        hub.waitForPendingDeliveries()
        #expect(sink.dataBytes == [0x62, 0xE6])
        #expect(sink.messages.last == .ended)
    }

    @Test func raisesABellForABareBelButNotForAnOscTitleUpdate() {
        let hub = PaneStreamHub()
        let bells = BellRecorder()
        hub.onBell = { bells.add($0) }
        // ESC ] 0 ; x BEL is a title update; the trailing 0x07 terminates it.
        hub.write(session: "%12", bytes: bytes("\u{1B}]0;x\u{07}"))
        #expect(bells.panes.isEmpty)
        hub.write(session: "%12", bytes: [0x07])
        #expect(bells.panes == ["%12"])
    }

    @Test func stopsDeliveringAfterDetach() {
        let hub = PaneStreamHub()
        let sink = Sink()
        let id = hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        hub.detach(connectionId: id)
        hub.write(session: "%12", bytes: bytes("x"))
        hub.flush()
        #expect(sink.messages.isEmpty)
    }

    // MARK: - Attaching

    /// A viewer is told the grid, and then sent the snapshot behind a full reset,
    /// and only then the live bytes. The reset is the hub's and appears once: the
    /// model's frame does not carry one of its own.
    @Test func anAttachIsTheGridThenTheSnapshotThenTheStream() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSnapshot = { _ in
            TerminalSnapshotFrame(size: TerminalSize(cols: 90, rows: 20), bytes: bytes("PAINT"), alternate: false)
        }
        hub.attach(session: "gt:1", resize: .repaint) { sink.receive($0) }
        hub.write(session: "gt:1", bytes: bytes("x"))
        hub.flush()
        #expect(sink.messages == [.resize(cols: 90, rows: 20, own: false),
                                  .snapshot(TerminalPaint.hardReset + bytes("PAINT")),
                                  .data(bytes("x"))])
    }

    /// `ESC c` exactly once at the front of a snapshot, with a real model behind
    /// the hook: two resets would be harmless on most receivers, but a receiver
    /// that counts what it was sent, or a frame that one day starts with its own,
    /// would show the seam.
    @Test func aSnapshotStartsWithOneFullReset() throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: 40, rows: 5))
        model.write(bytes("hello\r\n"))
        #expect(!model.snapshotFrame().bytes.starts(with: TerminalPaint.hardReset))
        let hub = PaneStreamHub()
        hub.onSnapshot = { _ in model.snapshotFrame() }
        let sink = Sink()
        hub.attach(session: "gt:1", resize: .reflow) { sink.receive($0) }
        guard case let .snapshot(frame) = try #require(sink.messages.dropFirst().first) else {
            Issue.record("expected a snapshot second")
            return
        }
        #expect(frame.starts(with: TerminalPaint.hardReset))
        #expect(!frame.dropFirst(TerminalPaint.hardReset.count).starts(with: TerminalPaint.hardReset))
    }

    // MARK: - Attaching to a session that cannot be streamed

    @Test func endsAViewerAttachingToAPaneTheServerNoLongerHolds() {
        // The socket used to upgrade and then stay silent forever, which a client
        // cannot tell apart from a pane that is simply idle.
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSnapshot = { _ in
            TerminalSnapshotFrame(size: TerminalSize(cols: 80, rows: 24), bytes: bytes("PAINT"), alternate: false)
        }
        hub.onSessionCensus = { .sessions(["%20"]) }

        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }

        #expect(sink.messages == [.ended])
        // Not registered either, so nothing arriving later reaches it.
        hub.write(session: "%12", bytes: bytes("x"))
        hub.flush()
        #expect(sink.messages == [.ended])
    }

    @Test func endsAViewerAttachingWithNoSessionIdAtAll() {
        // What a terminal row that was configured but never opened carries.
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSessionCensus = { .sessions(["%12"]) }
        hub.attach(session: "", resize: .repaint) { sink.receive($0) }
        #expect(sink.messages == [.ended])
    }

    @Test func endsAViewerWhenTheServerIsGoneEntirely() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSessionCensus = { .noServer }
        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        #expect(sink.messages == [.ended])
    }

    @Test func attachesNormallyWhenTheCensusListsThePane() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSnapshot = { _ in
            TerminalSnapshotFrame(size: TerminalSize(cols: 80, rows: 24), bytes: bytes("PAINT"), alternate: false)
        }
        hub.onSessionCensus = { .sessions(["%12", "%20"]) }

        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        hub.write(session: "%12", bytes: bytes("x"))
        hub.flush()

        #expect(sink.messages == [.resize(cols: 80, rows: 24, own: false),
                                  .snapshot(TerminalPaint.hardReset + bytes("PAINT")),
                                  .data(bytes("x"))])
    }

    /// The rule the three-valued census exists for: one failed query must not end
    /// a viewer whose pane is perfectly alive.
    @Test func keepsAViewerWhenTheCensusItselfFailed() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSnapshot = { _ in
            TerminalSnapshotFrame(size: TerminalSize(cols: 80, rows: 24), bytes: bytes("PAINT"), alternate: false)
        }
        hub.onSessionCensus = { .unknown }

        hub.attach(session: "%12", resize: .repaint) { sink.receive($0) }
        hub.write(session: "%12", bytes: bytes("x"))
        hub.flush()

        #expect(sink.messages == [.resize(cols: 80, rows: 24, own: false),
                                  .snapshot(TerminalPaint.hardReset + bytes("PAINT")),
                                  .data(bytes("x"))])
    }

    // MARK: - A grid that moves

    /// Every viewer is told the new grid another viewer claimed. A viewer that asked
    /// for repaints is sent the visible screen again behind the soft reset; one that
    /// reflows by itself gets nothing more. A claim that did not move the grid is
    /// answered to its claimant alone.
    @Test func aGridChangeTellsEveryViewerAndRepaintsOnlyThoseThatAskedForIt() {
        let hub = PaneStreamHub()
        hub.onRepaint = { _ in (size: TerminalSize(cols: 100, rows: 30), frame: bytes("SCREEN")) }
        let repainted = Sink()
        let reflowing = Sink()
        hub.attach(session: "gt:1", resize: .repaint) { repainted.receive($0) }
        hub.attach(session: "gt:1", resize: .reflow) { reflowing.receive($0) }
        let claimer = hub.attach(session: "gt:1", resize: .reflow) { _ in }

        hub.claim(connectionId: claimer, cols: 100, rows: 30)
        hub.claim(connectionId: claimer, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()

        #expect(repainted.messages == [.resize(cols: 100, rows: 30, own: false),
                                       .repaint(TerminalPaint.reset + bytes("SCREEN"))])
        #expect(reflowing.messages == [.resize(cols: 100, rows: 30, own: false)])
    }

    /// No repaint source, or one that could not build a frame: every viewer still
    /// learns the grid, and a size that really moved is told again.
    @Test func aClaimWithNothingToPaintStillTellsTheGrid() {
        // Paced, so the claims sent back to back are each handled at once.
        let hub = PaneStreamHub(claimClock: ClaimTimers.paced())
        let sink = Sink()
        hub.onRepaint = { _ in nil }
        hub.attach(session: "gt:1", resize: .repaint) { sink.receive($0) }
        let claimer = hub.attach(session: "gt:1", resize: .reflow) { _ in }

        hub.claim(connectionId: claimer, cols: 100, rows: 30)
        hub.claim(connectionId: claimer, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()

        #expect(sink.messages == [.resize(cols: 100, rows: 30, own: false)])

        hub.claim(connectionId: claimer, cols: 80, rows: 24)
        hub.waitForPendingDeliveries()
        #expect(sink.messages == [.resize(cols: 100, rows: 30, own: false),
                                  .resize(cols: 80, rows: 24, own: false)])
    }

    /// The bytes accepted before the repaint was taken reach the viewers ahead of
    /// it, so a repaint neither repeats them nor loses them.
    @Test func aRepaintDeliversWhatWasAcceptedBeforeIt() {
        let hub = PaneStreamHub()
        hub.onRepaint = { _ in (size: TerminalSize(cols: 100, rows: 30), frame: bytes("SCREEN")) }
        let sink = Sink()
        hub.attach(session: "gt:1", resize: .repaint) { sink.receive($0) }
        let claimer = hub.attach(session: "gt:1", resize: .reflow) { _ in }
        hub.waitForPendingDeliveries()
        // Past the quiet interval, and then two writes, so at least the second is
        // still in the buffer when the grid is claimed.
        usleep(20_000)
        hub.write(session: "gt:1", bytes: bytes("a"))
        hub.write(session: "gt:1", bytes: bytes("b"))
        hub.claim(connectionId: claimer, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        let messages = sink.messages
        let resize = messages.firstIndex(of: .resize(cols: 100, rows: 30, own: false))
        #expect(resize != nil)
        #expect(sink.dataBytes == bytes("ab"))
        // Every byte ahead of the grid, none behind it.
        #expect(messages.prefix(resize ?? 0).allSatisfy { if case .data = $0 { true } else { false } })
        #expect(messages.suffix(2) == [.resize(cols: 100, rows: 30, own: false),
                                      .repaint(TerminalPaint.reset + bytes("SCREEN"))])
    }
}

private final class BellRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var panes: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ pane: String) { lock.lock(); storage.append(pane); lock.unlock() }
}

/// The hub is the one streaming path, so a terminal's bytes reach a browser, an
/// iPad and another Mac through exactly the same code. Anything less means two
/// coalescing implementations and two bell detectors.
@Suite struct PaneStreamHubByteIngestionTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func writtenBytesReachAViewer() {
        let hub = PaneStreamHub()
        let received = Sink()
        hub.attach(session: "gt:1", resize: .repaint) { received.receive($0) }
        hub.write(session: "gt:1", bytes: bytes("hello"))
        hub.flush()
        #expect(received.dataBytes == bytes("hello"))
    }

    /// A bell in a written stream has to ring. The hub is the only place that
    /// holds the escape state needed to tell a real 0x07 from an OSC
    /// terminator, so a substrate that bypassed it would either miss bells or
    /// ring on every shell prompt.
    @Test func writtenBytesRingTheBell() {
        let hub = PaneStreamHub()
        let bells = Counter()
        hub.onBell = { _ in bells.bump() }
        hub.attach(session: "gt:1", resize: .repaint) { _ in }
        hub.write(session: "gt:1", bytes: bytes("a\u{07}b"))
        #expect(bells.count == 1)
    }

    /// The census answer is substrate neutral now, so the ghostty stack can
    /// answer it from its own registry.
    @Test func aSessionTheCensusDoesNotHoldIsEndedAtOnce() {
        let hub = PaneStreamHub()
        hub.onSessionCensus = { .sessions(["gt:1"]) }
        let ended = Flag()
        hub.attach(session: "gt:2", resize: .repaint) { if case .ended = $0 { ended.set() } }
        #expect(ended.isSet)
    }
}
