import Testing
import Foundation
@testable import Wietty

@Suite struct PaneStreamHubTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [RemoteMessage] = []
        var messages: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return storage }
        func receive(_ message: RemoteMessage) { lock.lock(); storage.append(message); lock.unlock() }
    }

    @Test func paintEmitsResizeThenDataWithClearAndCursor() {
        let messages = PaneStreamHub.paintMessages(rows: ["ab", "cd"], cursorX: 1, cursorY: 1,
                                                   cols: 2, rows: 2)
        #expect(messages.first == .resize(cols: 2, rows: 2))
        guard case let .data(vt) = messages[1] else { Issue.record("expected data"); return }
        #expect(vt.hasPrefix("\u{1B}[2J\u{1B}[H"))
        #expect(vt.contains("ab\r\ncd"))
        #expect(vt.hasSuffix("\u{1B}[2;2H"))   // cursor is 1-based in VT
    }

    @Test func deliversCoalescedOutputToASubscriber() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12") { sink.receive($0) }
        hub.write(session: "%12", bytes: Array("he".utf8))
        hub.write(session: "%12", bytes: Array("llo".utf8))
        #expect(sink.messages.isEmpty)      // nothing before a flush
        hub.flush()
        #expect(sink.messages == [.data("hello")])
    }

    @Test func doesNotDeliverOutputForAnotherPane() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12") { sink.receive($0) }
        hub.write(session: "%99", bytes: Array("nope".utf8))
        hub.flush()
        #expect(sink.messages.isEmpty)
    }

    @Test func deliversTheSamePaneToEveryViewer() {
        let hub = PaneStreamHub()
        let first = Sink()
        let second = Sink()
        hub.attach(session: "%12") { first.receive($0) }
        hub.attach(session: "%12") { second.receive($0) }
        hub.write(session: "%12", bytes: Array("x".utf8))
        hub.flush()
        #expect(first.messages == [.data("x")])
        #expect(second.messages == [.data("x")])
    }

    @Test func holdsBackASplitCharacterAcrossFlushes() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12") { sink.receive($0) }
        hub.write(session: "%12", bytes: [0x61, 0xC3])
        hub.flush()
        #expect(sink.messages == [.data("a")])
        hub.write(session: "%12", bytes: [0xA9])
        hub.flush()
        #expect(sink.messages == [.data("a"), .data("é")])
    }

    @Test func emitsNothingWhenThereIsNoBufferedOutput() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.attach(session: "%12") { sink.receive($0) }
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
        hub.attach(session: "gt:1") { doomed.receive($0) }
        hub.attach(session: "gt:1") { alsoWatching.receive($0) }
        hub.attach(session: "gt:2") { survivor.receive($0) }

        hub.endViewers(ofSession: "gt:1")
        hub.waitForPendingDeliveries()

        #expect(doomed.messages == [.ended])
        #expect(alsoWatching.messages == [.ended])
        #expect(survivor.messages.isEmpty)
        // The bytes of a session that has ended reach nobody: its viewers are gone
        // and its buffer went with them.
        hub.write(session: "gt:1", bytes: Array("late".utf8))
        hub.flush()
        #expect(doomed.messages == [.ended])
    }


    @Test func raisesABellForABareBelButNotForAnOscTitleUpdate() {
        let hub = PaneStreamHub()
        let bells = BellRecorder()
        hub.onBell = { bells.add($0) }
        // ESC ] 0 ; x BEL is a title update; the trailing 0x07 terminates it.
        hub.write(session: "%12", bytes: Array("\u{1B}]0;x\u{07}".utf8))
        #expect(bells.panes.isEmpty)
        hub.write(session: "%12", bytes: [0x07])
        #expect(bells.panes == ["%12"])
    }

    @Test func stopsDeliveringAfterDetach() {
        let hub = PaneStreamHub()
        let sink = Sink()
        let id = hub.attach(session: "%12") { sink.receive($0) }
        hub.detach(connectionId: id)
        hub.write(session: "%12", bytes: Array("x".utf8))
        hub.flush()
        #expect(sink.messages.isEmpty)
    }

    // MARK: - Attaching to a session that cannot be streamed

    @Test func endsAViewerAttachingToAPaneTheServerNoLongerHolds() {
        // The socket used to upgrade and then stay silent forever, which a client
        // cannot tell apart from a pane that is simply idle.
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onPaint = { _ in [.data("PAINT")] }
        hub.onSessionCensus = { .sessions(["%20"]) }

        hub.attach(session: "%12") { sink.receive($0) }

        #expect(sink.messages == [.ended])
        // Not registered either, so nothing arriving later reaches it.
        hub.write(session: "%12", bytes: Array("x".utf8))
        hub.flush()
        #expect(sink.messages == [.ended])
    }

    @Test func endsAViewerAttachingWithNoSessionIdAtAll() {
        // What a terminal row that was configured but never opened carries.
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSessionCensus = { .sessions(["%12"]) }
        hub.attach(session: "") { sink.receive($0) }
        #expect(sink.messages == [.ended])
    }

    @Test func endsAViewerWhenTheServerIsGoneEntirely() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onSessionCensus = { .noServer }
        hub.attach(session: "%12") { sink.receive($0) }
        #expect(sink.messages == [.ended])
    }

    @Test func attachesNormallyWhenTheCensusListsThePane() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onPaint = { _ in [.data("PAINT")] }
        hub.onSessionCensus = { .sessions(["%12", "%20"]) }

        hub.attach(session: "%12") { sink.receive($0) }
        hub.write(session: "%12", bytes: Array("x".utf8))
        hub.flush()

        #expect(sink.messages == [.data("PAINT"), .data("x")])
    }

    /// The rule the three-valued census exists for: one failed `list-panes` must
    /// not end a viewer whose pane is perfectly alive.
    @Test func keepsAViewerWhenTheCensusItselfFailed() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onPaint = { _ in [.data("PAINT")] }
        hub.onSessionCensus = { .unknown }

        hub.attach(session: "%12") { sink.receive($0) }
        hub.write(session: "%12", bytes: Array("x".utf8))
        hub.flush()

        #expect(sink.messages == [.data("PAINT"), .data("x")])
    }


    /// The substrate-neutral half of the same behaviour, which is what the
    /// libghostty substrate calls directly: it has no `%layout-change` to ingest and
    /// reports a grid it read from the surface instead.
    @Test func notingASizeTellsViewersAndDedupesARepeat() {
        let hub = PaneStreamHub()
        let sink = Sink()
        hub.onPaint = { _ in [] }       // no capture available: bare resize fallback
        hub.attach(session: "gt:1") { sink.receive($0) }

        hub.noteSize(session: "gt:1", TerminalSize(cols: 100, rows: 30))
        hub.noteSize(session: "gt:1", TerminalSize(cols: 100, rows: 30))
        hub.waitForPendingDeliveries()

        #expect(sink.messages == [.resize(cols: 100, rows: 30)])

        // A size that really moved is reported again.
        hub.noteSize(session: "gt:1", TerminalSize(cols: 80, rows: 24))
        hub.waitForPendingDeliveries()
        #expect(sink.messages == [.resize(cols: 100, rows: 30), .resize(cols: 80, rows: 24)])
    }

}

private final class PaintCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class BellRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var panes: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ pane: String) { lock.lock(); storage.append(pane); lock.unlock() }
}

/// The hub is the one streaming path, so a terminal's bytes reach the app's own
/// pane, a browser and an iPad through exactly the same code. Anything less means
/// two coalescing implementations, two UTF-8 boundary policies, and two bell
/// detectors.
@Suite struct PaneStreamHubByteIngestionTests {
    // Lock-guarded accumulators, not captured `var`s: every sink handed to
    // `attach` is stored as `@Sendable` and Swift 6 refuses a `@Sendable`
    // closure that mutates a captured local, the same reason `PaneStreamHubTests`
    // above uses `Sink`, `BellRecorder`, and `PaintCounter` instead of plain vars.
    private final class TextSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var texts: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        func receive(_ message: RemoteMessage) {
            guard case let .data(text) = message else { return }
            lock.lock(); storage.append(text); lock.unlock()
        }
    }

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
        let received = TextSink()
        hub.attach(session: "gt:1") { received.receive($0) }
        hub.write(session: "gt:1", bytes: Array("hello".utf8))
        hub.flush()
        #expect(received.texts == ["hello"])
    }


    /// A bell in a written stream has to ring. The hub is the only place that
    /// holds the escape state needed to tell a real 0x07 from an OSC
    /// terminator, so a substrate that bypassed it would either miss bells or
    /// ring on every shell prompt.
    @Test func writtenBytesRingTheBell() {
        let hub = PaneStreamHub()
        let bells = Counter()
        hub.onBell = { _ in bells.bump() }
        hub.attach(session: "gt:1") { _ in }
        hub.write(session: "gt:1", bytes: Array("a\u{07}b".utf8))
        #expect(bells.count == 1)
    }

    /// The census answer is substrate neutral now, so the ghostty stack can
    /// answer it from its own registry.
    @Test func aSessionTheCensusDoesNotHoldIsEndedAtOnce() {
        let hub = PaneStreamHub()
        hub.onSessionCensus = { .sessions(["gt:1"]) }
        let ended = Flag()
        hub.attach(session: "gt:2") { if case .ended = $0 { ended.set() } }
        #expect(ended.isSet)
    }
}
