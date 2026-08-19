import Testing
import Foundation
@testable import Wietty

/// Lock-guarded accumulator, not a captured `var`: a hub viewer's sink is
/// `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a captured
/// local. The same shape `GhosttyServiceTests`, `PaneStreamHubTests` and
/// `RawPTYTests` each keep for the same reason.
private final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
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
    private var storage: [RemoteMessage] = []
    func add(_ message: RemoteMessage) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// The same, for a sink that only has to record that something arrived.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

/// The substrate's composition root. Its contract is the same one `TmuxStack`
/// has: always construct, and say what is wrong through `setupError` rather than
/// failing every call site silently.
@MainActor
@Suite struct GhosttyStackTests {
    @Test func aMissingHelperIsAStartupError() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: nil)
        #expect(stack.setupError == TerminalError.ghosttyHelperMissing.errorDescription)
    }

    /// A stack that cannot work still constructs, so the app launches and can
    /// explain itself. Every terminal action then fails with the one actionable
    /// message instead of appearing to do nothing.
    @Test func abrokenStackStillServesAnActionableError() async {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: nil)
        #expect(stack.service is UnavailableTerminalService)
        await #expect(throws: TerminalError.self) {
            _ = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: nil, badge: nil)
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
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: nil)
        let ended = Flag()
        stack.hub.attach(session: "gt:anything") { if case .ended = $0 { ended.raise() } }
        #expect(ended.isRaised)
    }

    /// The reported reason and the thrown reason must be the same reason. They were
    /// briefly allowed to differ, and the result was a stack whose `setupError` said
    /// libghostty would not start while every terminal action told the user to
    /// reinstall the app for a missing helper, sending them to fix the wrong thing.
    @Test func aLibghosttyFailureIsReportedAndThrownAsTheSameError() async {
        let expected = TerminalError.ghosttyInitFailed("no Metal device")
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true",
                                 hostFailure: expected)
        #expect(stack.setupError == expected.errorDescription)
        await #expect(throws: expected) {
            _ = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: nil, badge: nil)
        }
    }

    @Test func aWorkingStackBuildsTheRealPieces() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        #expect(stack.setupError == nil)
        #expect(stack.service is GhosttyService)
        #expect(stack.monitor is GhosttyMonitor)
    }

    /// The hub is the one streaming path, so a terminal's bytes have to arrive in
    /// it without the service knowing the hub exists.
    @Test func terminalBytesReachTheHub() async throws {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "echo hubbed-21", badge: nil)
        // No `await` between the open and the attach on purpose: the child exits at
        // once, and the reap that follows it runs on this actor, so anything
        // suspending here would let the census answer `ended` before the viewer
        // ever registered.
        let seen = TextSink()
        stack.hub.attach(session: handle.sessionId) { message in
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
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: nil, badge: nil)
        let seen = TextSink()
        stack.hub.attach(session: handle.sessionId) { message in
            if case let .data(chunk) = message { seen.append(chunk) }
        }
        // Sent on every poll rather than once after a fixed settle. A shell reaching
        // its first read is not an event the test can observe, and a fixed sleep is
        // either a flake or slow; a repeated probe is neither, and a duplicate that
        // does land only prints a duplicate marker.
        try await waitUntil {
            stack.hub.send(session: handle.sessionId, text: "echo remote-$((20+1))\n")
            stack.hub.flush()
            return seen.contains("remote-21")
        }
    }

    /// Keystrokes arriving faster than the main actor can drain them reach the pty
    /// master in the order they were handed over.
    ///
    /// This is the rule the whole `onSend` design exists for: input order is as load
    /// bearing as output order, and a paste arrives as several messages in a row. A
    /// hub hook that bridged to the main actor with one unstructured `Task` per
    /// keystroke leaves that order to the scheduler, which is what
    /// `TmuxStack.onSend` refuses with its serial queue.
    ///
    /// `cat` rather than a shell, and no settle at all: a pty echoes what is written
    /// to its master back out of it as the write is processed, so the echo order IS
    /// the write order, whether or not the child has started reading yet. A shell
    /// would add its own startup, its own line editor, and nothing to the claim.
    @Test func rapidKeystrokesReachTheTerminalInOrder() async throws {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "cat", badge: nil)
        let seen = TextSink()
        stack.hub.attach(session: handle.sessionId) { message in
            if case let .data(chunk) = message { seen.append(chunk) }
        }
        // Back to back, with nothing awaited between them, which is the only way to
        // hand the hook more than it can deliver synchronously.
        stack.hub.send(session: handle.sessionId, text: "alpha-1\n")
        stack.hub.send(session: handle.sessionId, text: "beta-2\n")
        stack.hub.send(session: handle.sessionId, text: "gamma-3\n")
        try await waitUntil { stack.hub.flush(); return seen.contains("gamma-3") }
        let offsets = seen.firstOffsets(of: ["alpha-1", "beta-2", "gamma-3"])
        let alpha = try #require(offsets[0])
        let beta = try #require(offsets[1])
        let gamma = try #require(offsets[2])
        #expect(alpha < beta)
        #expect(beta < gamma)
    }

    /// A viewer attaching to a session the substrate does not hold must be ended
    /// at once rather than left on a socket that never speaks. A terminal row
    /// outlives its terminal so it can be restarted, and a row never opened has
    /// no session id at all, so the sidebar can offer an unattachable session at
    /// any time.
    @Test func attachingToADeadSessionEndsTheViewer() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let ended = Flag()
        stack.hub.attach(session: "gt:never-existed") { if case .ended = $0 { ended.raise() } }
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
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "exit 0", badge: nil)
        // No `await` between the open and the attach, for the reason
        // `terminalBytesReachTheHub` gives: the child exits at once, and a suspension
        // here would let the census answer `ended` before the viewer registered,
        // which is a different code path from the one under test.
        let ended = Flag()
        stack.hub.attach(session: handle.sessionId) { if case .ended = $0 { ended.raise() } }
        try await waitUntil { ended.isRaised }
    }

    /// And when the row is closed, which is the other way a terminal ends. The viewer
    /// has no more claim on a closed row than on an exited one, and the same silence
    /// follows if nobody tells it.
    @Test func anAttachedViewerIsToldWhenTheRowIsClosed() async throws {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "sleep 30", badge: nil)
        let ended = Flag()
        stack.hub.attach(session: handle.sessionId) { if case .ended = $0 { ended.raise() } }
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
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "echo parted-$((7+6))", badge: nil)
        // No `await` between the open and the attach, for the reason above.
        let log = MessageLog()
        stack.hub.attach(session: handle.sessionId) { log.add($0) }
        try await waitUntil { log.messages.contains(.ended) }

        let ending = try #require(log.messages.firstIndex(of: .ended))
        let printed = log.messages.prefix(ending).contains { message in
            guard case let .data(chunk) = message else { return false }
            return chunk.contains("parted-13")
        }
        #expect(printed)
    }

    /// A viewer attaching to a live terminal is handed the recorded screen before
    /// any live byte, or it faces a blank one until something happens to change it.
    ///
    /// The geometry is asserted, not just the text. `paintMessages` takes a cursor
    /// column, a cursor row, a width and a height in that order, all four of them
    /// `Int`, so a pair swapped there compiles, renders plausibly, and puts every
    /// remote cursor in the wrong place.
    @Test func aViewerAttachingToALiveTerminalIsPaintedTheRecordedScreen() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack(host: host, helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "sleep 5", badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["alpha", "beta"], cols: 80,
                                                          cursorX: 3, cursorY: 1)
        // A resize is one of the two moments the service records the shared
        // snapshot, and the only one a test can trigger from outside.
        host.emitResize(handle.sessionId, TerminalSize(cols: 80, rows: 2))
        let log = MessageLog()
        stack.hub.attach(session: handle.sessionId) { log.add($0) }
        #expect(log.messages.first == .resize(cols: 80, rows: 2))
        let painted = try #require(log.messages.dropFirst().first)
        #expect(painted == .data("\u{1B}[2J\u{1B}[Halpha\r\nbeta\u{1B}[2;4H"))
    }

    /// An already attached viewer is told when the grid moves.
    ///
    /// A viewer learns its size in the paint it receives on attach and from nothing
    /// else, so this hook is the only thing standing between a window resize and
    /// every remote viewer rendering reflowed bytes against the old grid until it
    /// reattaches. The report comes from the surface, so the stack has to carry it
    /// into the hub itself.
    @Test func resizingATerminalTellsItsViewersTheNewGrid() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack(host: host, helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "sleep 5", badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["before"], cols: 80)
        host.emitResize(handle.sessionId, TerminalSize(cols: 80, rows: 1))
        // Drained before the viewer exists, or this test races itself: that first
        // report queues a repaint on the hub's delivery queue, and if it lands after
        // the attach below it delivers this screen to the new viewer and everything
        // counted from `afterAttach` is shifted by two messages.
        stack.hub.waitForPendingDeliveries()

        let log = MessageLog()
        stack.hub.attach(session: handle.sessionId) { log.add($0) }
        let afterAttach = log.messages.count

        // The reflowed screen, and then the grid that produced it. A grid's worth of
        // rows, as the real host's viewport read always returns.
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: (1...30).map { "row \($0)" },
                                                          cols: 100)
        host.emitResize(handle.sessionId, TerminalSize(cols: 100, rows: 30))
        stack.hub.waitForPendingDeliveries()

        let sent = Array(log.messages.dropFirst(afterAttach))
        #expect(sent.first == .resize(cols: 100, rows: 30))
        // The repaint carries the screen recorded AFTER the reflow, not the one from
        // before it: the service records and only then reports, and a hook wired the
        // other way round would paint "before" over a reflowed terminal.
        guard case let .data(vt) = try #require(sent.dropFirst().first) else {
            Issue.record("expected the reflowed screen")
            return
        }
        #expect(vt.contains("row 30"))
        #expect(!vt.contains("before"))
    }

    /// A keystroke into the pane's surface reaches whatever the app wired `onInput`
    /// to, so the store can drop that terminal's attention flag. Forwarded to the
    /// host because the host is private to this stack, and unclaimed by the substrate
    /// itself, which reads only output.
    @Test func surfaceInputReachesTheWiredHandler() {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack(host: host, helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        var typed: [String] = []
        stack.onInput = { session in typed.append(session) }
        host.emitInput("gt:sess-A")
        #expect(typed == ["gt:sess-A"])
    }

    /// The job poll the store is handed has to be bound to this stack, or it
    /// answers nothing and every agent's status freezes.
    @Test func theJobPollIsBoundToThisStack() async throws {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let handle = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                  existingWindowId: nil,
                                                  command: "sleep 5", badge: nil)
        let poll = stack.pollJobs
        try await waitUntil {
            poll().contains(.job(sessionId: handle.sessionId, jobName: "sleep"))
        }
    }

    /// The socket sweep takes what a crashed run left behind and leaves what a live
    /// terminal is using.
    ///
    /// Age is the whole predicate, because the name cannot carry an owner: the
    /// `sun_path` budget is already spent. Without it the sweep unlinks the socket of
    /// any other Wietty sharing the temp directory, and the socket of a relay in
    /// this process that has bound but whose helper has not connected yet, which is a
    /// terminal that then produces nothing with no visible cause.
    @Test func theSocketSweepSparesSocketsYoungEnoughToBeInUse() throws {
        let directory = NSTemporaryDirectory()
        let tag = UInt32.random(in: 0..<0xFFFFFF)
        let fresh = directory + "ipx-fresh\(tag).sock"
        let abandoned = directory + "ipx-old\(tag).sock"
        try Data().write(to: URL(fileURLWithPath: fresh))
        try Data().write(to: URL(fileURLWithPath: abandoned))
        defer {
            unlink(fresh)
            unlink(abandoned)
        }
        let old = Date(timeIntervalSinceNow: -GhosttyStack.staleSocketAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: abandoned)

        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        stack.clearStaleSockets()

        #expect(FileManager.default.fileExists(atPath: fresh))
        #expect(FileManager.default.fileExists(atPath: abandoned) == false)
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
