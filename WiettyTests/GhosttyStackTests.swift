import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// Lock-guarded accumulator, not a captured `var`: a hub viewer's sink is
/// `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a captured
/// local. The same shape `GhosttyServiceTests`, `PaneStreamHubTests` and
/// `RawPTYTests` each keep for the same reason.
private final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    func append(_ bytes: [UInt8]) { append(String(decoding: bytes, as: UTF8.self)) }
    func contains(_ needle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage.contains(needle)
    }
    /// Where each needle first appears, or nil for one that never did. The order
    /// of the answers is what an ordering assertion is made of.
    func firstOffsets(of needles: [String]) -> [Int?] {
        lock.lock(); defer { lock.unlock() }
        return needles.map { needle in
            storage.range(of: needle).map { storage.distance(from: storage.startIndex,
                                                             to: $0.lowerBound) }
        }
    }
}

/// The same, for the tests that care which messages arrived and in what order.
private final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamMessage] = []
    func add(_ message: StreamMessage) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// The same, for a sink that only has to record that something arrived.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

/// The substrate's composition root. Its contract: always construct, and say what
/// is wrong through `setupError` rather than failing every call site silently.
@MainActor
@Suite struct GhosttyStackTests {
    /// A local socket that cannot be bound is a startup error of its own, reported
    /// and thrown as the same error, like a missing helper. The panes reach their
    /// terminals only through it.
    @Test func aLocalSocketThatCannotBeBoundIsAStartupError() async {
        let stack = GhosttyStack(host: FakeSurfaceHost(), localSocketPath: "not-absolute.sock")
        let expected = TerminalError.localSocketFailed(
            String(describing: LocalSocketError.relativeSocketPath("not-absolute.sock")))
        #expect(stack.setupError == expected.errorDescription)
        #expect(stack.localServer == nil)
        await #expect(throws: expected) {
            _ = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: nil)
        }
    }

    /// The local socket server runs on every working stack, remote access or not,
    /// and `shutDown()` (what quitting calls) stops it and removes its socket file.
    @Test func aWorkingStackServesItsLocalSocketUntilShutDown() throws {
        let path = testServerSocketPath()
        let stack = GhosttyStack(host: FakeSurfaceHost(), localSocketPath: path, readDelay: 0)
        #expect(stack.localSocketPath == path)
        #expect(stack.localServer != nil)
        let client = try UnixTestSocket(connectingTo: path)
        client.close()
        stack.shutDown()
        #expect(FileManager.default.fileExists(atPath: path) == false)
        #expect(throws: (any Error).self) { try UnixTestSocket(connectingTo: path) }
    }

    /// A stack that cannot work still constructs, so the app launches and can
    /// explain itself. Every terminal action then fails with the one actionable
    /// message instead of appearing to do nothing.
    @Test func abrokenStackStillServesAnActionableError() async {
        let stack = GhosttyStack(host: FakeSurfaceHost(), localSocketPath: testServerSocketPath(),
                                 startupFailure: .ghosttyHelperMissing)
        #expect(stack.service is UnavailableTerminalService)
        await #expect(throws: TerminalError.self) {
            _ = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: nil)
        }
    }

    /// A stack that could not be built answers an attach instead of leaving it on a
    /// socket that never speaks.
    ///
    /// Leaving the census unwired would mean `.unknown`, and an `.unknown` must not
    /// end a viewer watching a terminal that is fine. A stack with no service holds
    /// nothing with certainty, and the sidebar can offer such a session at any time,
    /// including a row that was never opened.
    @Test func abrokenStackEndsAnAttachRatherThanLeavingItSilent() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), localSocketPath: testServerSocketPath(),
                                 startupFailure: .ghosttyHelperMissing)
        let ended = Flag()
        stack.hub.attach(session: "gt:anything", resize: .repaint) { if case .ended = $0 { ended.raise() } }
        #expect(ended.isRaised)
    }

    /// The reported reason and the thrown reason must be the same reason. They were
    /// briefly allowed to differ, and the result was a stack whose `setupError` said
    /// libghostty would not start while every terminal action told the user to
    /// reinstall the app for a missing helper, sending them to fix the wrong thing.
    @Test func aLibghosttyFailureIsReportedAndThrownAsTheSameError() async {
        let expected = TerminalError.ghosttyInitFailed("no Metal device")
        let stack = GhosttyStack(host: FakeSurfaceHost(), localSocketPath: testServerSocketPath(),
                                 startupFailure: expected)
        #expect(stack.setupError == expected.errorDescription)
        await #expect(throws: expected) {
            _ = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: nil)
        }
    }

    @Test func aWorkingStackBuildsTheRealPieces() {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        #expect(stack.setupError == nil)
        #expect(stack.service is GhosttyService)
        #expect(stack.monitor is GhosttyMonitor)
    }

    /// The hub is the one streaming path, so a terminal's bytes have to arrive in
    /// it without the service knowing the hub exists.
    @Test func terminalBytesReachTheHub() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "echo hubbed-21")
        // No `await` between the open and the attach on purpose: the child exits at
        // once, and the reap that follows it runs on this actor, so anything
        // suspending here would let the census answer `ended` before the viewer
        // ever registered.
        let seen = TextSink()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { message in
            if case let .data(chunk) = message { seen.append(chunk) }
        }
        try await waitUntil { stack.hub.flush(); return seen.contains("hubbed-21") }
    }

    /// A remote viewer's keystrokes reach the pty master, which is the same path a
    /// local keystroke takes.
    ///
    /// The marker is arithmetic the shell has to evaluate. A pty echoes whatever is
    /// written to its master straight back out of it, so a literal marker would
    /// prove only that something was written; `remote-21` can only come from a
    /// shell that read the line.
    @Test func remoteKeystrokesReachTheTerminal() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: nil)
        let seen = TextSink()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { message in
            if case let .data(chunk) = message { seen.append(chunk) }
        }
        // Sent on every poll rather than once after a fixed settle. A shell reaching
        // its first read is not an event the test can observe, and a fixed sleep is
        // either a flake or slow; a repeated probe is neither, and a duplicate that
        // does land only prints a duplicate marker.
        try await waitUntil {
            stack.hub.send(session: handle.sessionId, bytes: Array("echo remote-$((20+1))\n".utf8))
            stack.hub.flush()
            return seen.contains("remote-21")
        }
    }

    /// Keystrokes arriving faster than the main actor can drain them reach the pty
    /// master in the order they were handed over.
    ///
    /// Input order is as load bearing as output order, and a paste arrives as
    /// several messages in a row. The hub hands each one to the terminal's writer on
    /// the caller's thread, and the writer queues it on the pty's own serial queue,
    /// so the order the caller sent them in is the order they reach the master. A
    /// hop through one unstructured `Task` per keystroke would leave it to the
    /// scheduler.
    ///
    /// `cat` rather than a shell, and no settle at all: a pty echoes what is written
    /// to its master back out of it as the write is processed, so the echo order IS
    /// the write order, whether or not the child has started reading yet. A shell
    /// would add its own startup, its own line editor, and nothing to the claim.
    @Test func rapidKeystrokesReachTheTerminalInOrder() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "cat")
        let seen = TextSink()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { message in
            if case let .data(chunk) = message { seen.append(chunk) }
        }
        // Back to back, with nothing awaited between them, which is the only way to
        // hand the hook more than it can deliver synchronously.
        stack.hub.send(session: handle.sessionId, bytes: Array("alpha-1\n".utf8))
        stack.hub.send(session: handle.sessionId, bytes: Array("beta-2\n".utf8))
        stack.hub.send(session: handle.sessionId, bytes: Array("gamma-3\n".utf8))
        try await waitUntil { stack.hub.flush(); return seen.contains("gamma-3") }
        let offsets = seen.firstOffsets(of: ["alpha-1", "beta-2", "gamma-3"])
        let alpha = try #require(offsets[0])
        let beta = try #require(offsets[1])
        let gamma = try #require(offsets[2])
        #expect(alpha < beta)
        #expect(beta < gamma)
    }

    /// A remote viewer's input reaches the terminal with the main actor busy.
    ///
    /// The hub hands it to the writer the service registered for the session, on
    /// the thread it arrived on. It used to go through the main actor, so a UI that
    /// was busy held every remote keystroke back for as long as it was. This test
    /// is that busy main actor: it waits on the semaphore without yielding, so a
    /// path through the main actor could only time out.
    @Test func inputReachesTheWriterWhileTheMainActorIsBlocked() throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let shared = try #require(stack.ghosttyService?.shared)
        let arrived = DispatchSemaphore(value: 0)
        shared.register(writer: { bytes in if bytes == [0x71] { arrived.signal() } }, for: "gt:blocked")
        let hub = stack.hub
        DispatchQueue.global().async { hub.send(session: "gt:blocked", bytes: [0x71]) }
        #expect(arrived.wait(timeout: .now() + 3) == .success)
    }

    /// A viewer attaching to a session the substrate does not hold must be ended
    /// at once rather than left on a socket that never speaks. A terminal row
    /// outlives its terminal so it can be restarted, and a row never opened has
    /// no session id at all, so the sidebar can offer an unattachable session at
    /// any time.
    @Test func attachingToADeadSessionEndsTheViewer() {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let ended = Flag()
        stack.hub.attach(session: "gt:never-existed", resize: .repaint) { if case .ended = $0 { ended.raise() } }
        #expect(ended.isRaised)
    }

    /// A viewer that is already watching is told when the terminal ends.
    ///
    /// The census answers an attach that has not happened yet, and nothing else on
    /// this substrate ever says a terminal is over: there is no `%window-close`
    /// equivalent, because the terminal is a PTY in this process. So without this
    /// wiring a browser or an iPad watching a terminal whose command exited went
    /// silent forever, indistinguishable from an idle terminal, which is exactly the
    /// state the census exists to prevent for a viewer arriving later.
    @Test func anAttachedViewerIsToldWhenTheChildExits() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "exit 0")
        // No `await` between the open and the attach, for the reason
        // `terminalBytesReachTheHub` gives: the child exits at once, and a suspension
        // here would let the census answer `ended` before the viewer registered,
        // which is a different code path from the one under test.
        let ended = Flag()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { if case .ended = $0 { ended.raise() } }
        try await waitUntil { ended.isRaised }
    }

    /// And when the row is closed, which is the other way a terminal ends. The viewer
    /// has no more claim on a closed row than on an exited one, and the same silence
    /// follows if nobody tells it.
    @Test func anAttachedViewerIsToldWhenTheRowIsClosed() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "sleep 30")
        let ended = Flag()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { if case .ended = $0 { ended.raise() } }
        #expect(ended.isRaised == false)
        try await stack.service.close(sessionId: handle.sessionId)
        stack.hub.waitForPendingDeliveries()
        #expect(ended.isRaised)
    }

    /// And the ending must not overtake the output. A command that prints and exits
    /// does both inside one 8 ms flush interval, so the bytes are still in the hub's
    /// buffer when the terminal ends: an ending that dropped them showed a browser
    /// watching `echo` a session that ended and never what it printed.
    @Test func theLastOutputReachesAViewerBeforeTheEnding() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "echo parted-$((7+6))")
        // No `await` between the open and the attach, for the reason above.
        let log = MessageLog()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { log.add($0) }
        try await waitUntil { log.messages.contains(.ended) }

        let ending = try #require(log.messages.firstIndex(of: .ended))
        let printed = log.messages.prefix(ending).contains { message in
            guard case let .data(chunk) = message else { return false }
            return String(decoding: chunk, as: UTF8.self).contains("parted-13")
        }
        #expect(printed)
    }

    /// A viewer attaching to a live terminal is handed its screen before any live
    /// byte, or it faces a blank one until something happens to change it.
    ///
    /// The screen is the one the core's own model holds, so it is coloured and
    /// the cursor is where the terminal has it, neither of which the frame this
    /// replaced could say. The grid comes first, because a viewer learns its size
    /// from this and from nothing else. Read back through a terminal rather than
    /// matched as bytes: where things end up is the contract.
    @Test func aViewerAttachingToALiveTerminalIsPaintedTheScreenTheModelHolds() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack.testing(host: host)
        defer { stack.shutDown() }
        let handle = try await stack.service.open(
            folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
            command: #"printf '\033[31malpha\033[0m\r\nbeta-%s' $((3+4)); sleep 5"#)
        let model = try #require(stack.ghosttyService?.screenModel(for: handle.sessionId))
        try await waitUntil { model.text(maxLines: 10).contains("beta-7") }
        let claimer = stack.hub.attach(session: handle.sessionId, resize: .reflow) { _ in }
        stack.hub.claim(connectionId: claimer, cols: 80, rows: 10)
        stack.hub.waitForPendingDeliveries()

        let log = MessageLog()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { log.add($0) }
        #expect(log.messages.first == .resize(cols: 80, rows: 10, own: false))
        guard case let .snapshot(vt) = try #require(log.messages.dropFirst().first) else {
            Issue.record("expected the snapshot")
            return
        }
        #expect(vt.starts(with: TerminalPaint.hardReset))
        #expect(String(decoding: vt, as: UTF8.self).contains("\u{1B}[38;5;1malpha"))
        let viewer = try GhosttyVtTerminal(size: TerminalSize(cols: 80, rows: 10), scrollbackLines: 0)
        viewer.write(vt)
        #expect(viewer.viewportLines() == ["alpha", "beta-7"])
        #expect(viewer.cursor == (x: 6, y: 1))
    }

    /// An already attached viewer is told when another viewer's claim moves the grid.
    ///
    /// A viewer learns its size in the paint it receives on attach and from
    /// `resize` messages, so this is what stands between another viewer's claim and
    /// this one rendering reflowed bytes against the old grid until it reattaches.
    @Test func resizingATerminalTellsItsViewersTheNewGrid() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack.testing(host: host)
        defer { stack.shutDown() }
        // Ninety columns of output: two rows on a grid of eighty, one on a hundred.
        let handle = try await stack.service.open(
            folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
            command: #"printf '%090d' $((40+2)); sleep 5"#)
        let line = String(repeating: "0", count: 88) + "42"
        let model = try #require(stack.ghosttyService?.screenModel(for: handle.sessionId))
        let answers = MessageLog()
        let claimer = stack.hub.attach(session: handle.sessionId, resize: .reflow) { answers.add($0) }
        stack.hub.claim(connectionId: claimer, cols: 80, rows: 5)
        try await waitUntil { model.text(maxLines: 10).contains("042") }
        // Drained before the viewer exists, or this test races itself: that first
        // claim queues a resize on the hub's delivery queue, and if it lands after
        // the attach below it delivers this screen to the new viewer and everything
        // counted from `afterAttach` is shifted by two messages.
        stack.hub.waitForPendingDeliveries()

        let log = MessageLog()
        stack.hub.attach(session: handle.sessionId, resize: .repaint) { log.add($0) }
        let afterAttach = log.messages.count

        stack.hub.claim(connectionId: claimer, cols: 100, rows: 30)
        // Waited for by its answer, not by the delivery queue: a second claim from
        // the same viewer within 50 ms of the first is held by the hub, and the
        // queue is empty while it waits. Once the claimant has its answer the claim
        // is being handled on the queue, and the barrier waits for the rest of it.
        try await waitUntil { answers.messages.contains(.resize(cols: 100, rows: 30, own: true)) }
        stack.hub.waitForPendingDeliveries()

        let sent = Array(log.messages.dropFirst(afterAttach))
        #expect(sent.first == .resize(cols: 100, rows: 30, own: false))
        // The repaint carries the screen as it is AFTER the reflow: the claim resizes
        // the model before the hub takes its repaint, and the other way round would
        // paint the wrapped line over a terminal that has unwrapped it.
        guard case let .repaint(vt) = try #require(sent.dropFirst().first) else {
            Issue.record("expected the reflowed screen")
            return
        }
        let viewer = try GhosttyVtTerminal(size: TerminalSize(cols: 100, rows: 30), scrollbackLines: 0)
        viewer.write(vt)
        #expect(viewer.viewportLines() == [line])
    }

    /// Two viewers of one terminal, the pane's kind (a local viewer through the stack's
    /// own socket server, as a bridge's link attaches) and a remote one (queued, as the
    /// attach route's), claim in turn. Each claim resizes the model, and each viewer
    /// is told every grid with `own` true exactly for its own claim.
    @Test func aLocalAndARemoteViewerClaimInTurnAndEachSeesWhoseItIs() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil, command: "sleep 30")
        let model = try #require(stack.ghosttyService?.screenModel(for: handle.sessionId))
        let local = MessageLog()
        let link = LocalSocketLink(path: stack.localSocketPath, session: handle.sessionId)
        defer { link.stop() }
        link.onMessage = { local.add($0) }
        link.start()
        try await waitUntil { local.messages.contains { if case .snapshot = $0 { true } else { false } } }
        let remote = MessageLog()
        let viewer = stack.hub.attach(session: handle.sessionId, resize: .repaint) { remote.add($0) }
        let localBefore = local.messages.count
        let remoteBefore = remote.messages.count

        func resizes(_ log: MessageLog, after count: Int) -> [StreamMessage] {
            log.messages.dropFirst(count).filter { if case .resize = $0 { true } else { false } }
        }

        link.claim(cols: 90, rows: 25)
        try await waitUntil { resizes(remote, after: remoteBefore).count == 1 }
        #expect(model.size == TerminalSize(cols: 90, rows: 25))
        stack.hub.claim(connectionId: viewer, cols: 70, rows: 20)
        try await waitUntil { resizes(local, after: localBefore).count == 2 }
        stack.hub.waitForPendingDeliveries()
        #expect(model.size == TerminalSize(cols: 70, rows: 20))

        #expect(resizes(local, after: localBefore) == [.resize(cols: 90, rows: 25, own: true),
                                                       .resize(cols: 70, rows: 20, own: false)])
        #expect(resizes(remote, after: remoteBefore) == [.resize(cols: 90, rows: 25, own: false),
                                                         .resize(cols: 70, rows: 20, own: true)])
    }

    /// A keystroke into the pane's surface reaches whatever the app wired `onInput`
    /// to, so the store can drop that terminal's attention flag. Forwarded to the
    /// host because the host is private to this stack, and unclaimed by the substrate
    /// itself, which reads only output.
    @Test func surfaceInputReachesTheWiredHandler() {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack.testing(host: host)
        defer { stack.shutDown() }
        var typed: [String] = []
        stack.onInput = { session in typed.append(session) }
        host.emitInput("gt:sess-A")
        #expect(typed == ["gt:sess-A"])
    }

    /// A report a program prints reaches the monitor, which is the app's one
    /// listener, against the session that printed it. It arrives on the main actor,
    /// because that is where the listener runs.
    @Test func aProgramStatusReportReachesTheMonitor() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        var events: [MonitorEvent] = []
        stack.monitor.start { events.append($0) }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: #"printf '\033]7501;state=working\033\\'"#)
        let working = MonitorEvent.programStatus(
            sessionId: handle.sessionId,
            .report(.set(id: nil, ProgramStatusRecord(state: .working))))
        try await waitUntil { events.contains(working) }
    }

    /// The job poll the store is handed has to be bound to this stack, or it
    /// answers nothing and every agent's status freezes.
    @Test func theJobPollIsBoundToThisStack() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "sleep 5")
        let poll = stack.pollJobs
        try await waitUntil {
            poll().contains(.job(sessionId: handle.sessionId, jobName: "sleep"))
        }
    }

    /// Polls a condition instead of sleeping a fixed time. A real shell reaching
    /// its first read is not an event the test can observe, and a fixed sleep is
    /// either a flake or slow.
    private func waitUntil(timeout: Duration = .seconds(6),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Bool(false), "condition never became true")
    }
}
