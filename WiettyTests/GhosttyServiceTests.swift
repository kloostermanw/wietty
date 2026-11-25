import Darwin
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Lock-guarded accumulator keyed by session, not a captured `var`: the output
/// handler is `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a
/// captured local.
private final class SessionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    func append(_ bytes: [UInt8], for session: String) {
        lock.lock()
        storage[session, default: ""] += String(decoding: bytes, as: UTF8.self)
        lock.unlock()
    }
    func text(for session: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return storage[session] ?? ""
    }
}

/// The program status events the service reported, keyed by session.
private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [ProgramStatusScanner.Event]] = [:]
    func add(_ session: String, _ event: ProgramStatusScanner.Event) {
        lock.lock(); storage[session, default: []].append(event); lock.unlock()
    }
    func events(for session: String) -> [ProgramStatusScanner.Event] {
        lock.lock(); defer { lock.unlock() }
        return storage[session] ?? []
    }
}

/// Records what the service reported terminated. A class rather than a captured
/// `var`, because the callback escapes.
@MainActor private final class TerminationLog {
    var ids: [String] = []
}

/// Reads the shared registry from outside the main actor, which is the only way
/// `PaneStreamHub` can read it: it asks from its own delivery queue and cannot
/// wait for a hop. Nonisolated on purpose, so this is a compile time assertion
/// that `shared` stays reachable without one.
private func liveSessionsOffTheMainActor(_ service: GhosttyService) -> Set<String> {
    service.shared.liveSessions
}

@MainActor
@Suite struct GhosttyServiceTests {
    private func service(_ host: FakeSurfaceHost,
                         onOutput: @escaping @Sendable (String, [UInt8]) -> Void = { _, _ in },
                         onProgramStatus: @escaping @Sendable (String, ProgramStatusScanner.Event) -> Void = { _, _ in },
                         onTerminated: @escaping @MainActor (String) -> Void = { _ in })
        -> GhosttyService {
        GhosttyService(host: host, readDelay: 0,
                       onOutput: onOutput, onProgramStatus: onProgramStatus,
                       onTerminated: onTerminated)
    }

    /// A service wired as the app wires it, for the tests that read a terminal
    /// back. Through the stack, because the service does not write a screen model
    /// itself: the hub does, and the stack is what connects the two. The service
    /// keeps the hub alive through the hooks it was built with.
    private func wiredService(_ host: FakeSurfaceHost) throws -> GhosttyService {
        try #require(GhosttyStack.testing(host: host).ghosttyService)
    }

    /// A program asking whether the terminal speaks `OSC 7501` gets the answer on
    /// its own stdin, byte for byte. The child puts its tty in raw mode first so the
    /// reply is neither echoed nor held for a newline, then prints what it read as
    /// hex, which only a reply that really arrived can produce.
    @Test func aProgramStatusQueryIsAnsweredOnThePty() async throws {
        let host = FakeSurfaceHost()
        let seen = SessionSink()
        let service = service(host, onOutput: { session, bytes in
            seen.append(bytes, for: session)
        })
        defer { service.closeAll() }
        let command = #"stty raw -echo; printf '\033]7501;?\033\\'; "#
            + #"r=$(dd bs=1 count=10 2>/dev/null | od -An -tx1 | tr -d ' \n'); stty sane; echo "got:$r""#
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: command, badge: nil)
        try await waitUntil { seen.text(for: handle.sessionId).contains("got:1b5d373530313b3f1b5c") }
    }

    @Test func aProgramStatusReportIsReportedAgainstItsSession() async throws {
        let host = FakeSurfaceHost()
        let reported = StatusLog()
        let service = service(host, onProgramStatus: { session, event in
            reported.add(session, event)
        })
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil,
                                            command: #"printf '\033]7501;state=done:msg=aGk=\033\\'"#,
                                            badge: nil)
        let done = ProgramStatusScanner.Event.report(
            .set(id: nil, ProgramStatusRecord(state: .done, msg: "hi")))
        try await waitUntil { reported.events(for: handle.sessionId) == [done] }
    }

    @Test func openingMintsASessionAndASurface() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: nil, badge: nil)
        #expect(handle.sessionId.hasPrefix("gt:"))
        #expect(host.created == [handle.sessionId])
        #expect(service.liveSessions == [handle.sessionId])
        // The registry the hub reads has to agree, and has to be readable from
        // where the hub reads it.
        #expect(liveSessionsOffTheMainActor(service) == [handle.sessionId])
    }

    /// The core asks the host for a surface for the session, in the terminal's
    /// folder, and builds no command: what the surface runs to reach the stream (the
    /// helper, pointed at its bridge) is the host's business. Never the user's shell
    /// either way: libghostty spawning the shell itself would leave Wietty owning no
    /// byte stream.
    @Test func theSurfaceIsAskedForBySessionAndFolderAlone() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let folder = URL(fileURLWithPath: "/private/tmp")
        let handle = try await service.open(folder: folder, existingWindowId: nil,
                                            command: nil, badge: nil)
        #expect(host.created == [handle.sessionId])
        #expect(host.directories[handle.sessionId] == folder)
    }

    /// A stored workspace id must survive. Nothing reads it, and minting one here
    /// would invent a name that then looks like something the app chose.
    @Test func aStoredWorkspaceIdIsEchoedBackUnchanged() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: "w0t2p0", command: nil, badge: nil)
        #expect(handle.windowId == "w0t2p0")
    }

    /// The badge reaches the surface as its title.
    ///
    /// That is as far as it goes today: libghostty has no title setter of any
    /// kind, so `GhosttySurfaceHost` keeps it as its own record and hangs it on
    /// the view's accessibility label, and nothing a sighted user sees is
    /// labelled by it. Asserted anyway, because the alternative is a substrate
    /// that silently drops a workspace setting the other two honour.
    @Test func theBadgeIsHandedToTheSurfaceAsItsTitle() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: nil, badge: "api")
        #expect((host.titles[handle.sessionId] ?? nil) == "api")
    }

    /// A surface that will not create leaves nothing behind. Without the cleanup
    /// the shell keeps running with no renderer and no way to reach it.
    @Test func aFailedSurfaceLeavesNoTerminal() async throws {
        let host = FakeSurfaceHost()
        host.failNextCreate = true
        let service = service(host)
        defer { service.closeAll() }
        var asked: String?
        host.whileCreating = { asked = $0 }
        await #expect(throws: (any Error).self) {
            _ = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                        existingWindowId: nil, command: nil, badge: nil)
        }
        let session = try #require(asked)
        #expect(service.liveSessions.isEmpty)
        // Taken back out of everything the hub reads, so a viewer that attaches to
        // it is answered `ended`, and never read.
        #expect(service.shared.liveSessions.isEmpty)
        #expect(service.screenModel(for: session) == nil)
        #expect(service.shared.writer(for: session) == nil)
        #expect(service.shared.resizer(for: session) == nil)
        #expect(service.shared.takeReadStart(for: session) == nil)
    }

    /// Output reaches the callback tagged with its session, which is what
    /// `PaneStreamHub.write` needs to fan it out.
    @Test func outputIsReportedAgainstItsSession() async throws {
        let host = FakeSurfaceHost()
        let seen = SessionSink()
        let service = service(host, onOutput: { session, bytes in
            seen.append(bytes, for: session)
        })
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil,
                                            command: "echo tagged-$((6+7))", badge: nil)
        try await waitUntil { seen.text(for: handle.sessionId).contains("tagged-13") }
    }

    /// `.terminated` has two sources on this substrate, the child exiting and the
    /// row's stop button, and both go through `reap`. Without it a finished row
    /// stays marked running for the life of the app.
    ///
    /// The handler is told last, after the terminal has left the census. A handler
    /// that asks what is running (which is exactly what a row updating itself
    /// does) must not be shown the terminal it is being told about.
    @Test func anExitingChildIsReported() async throws {
        let host = FakeSurfaceHost()
        let ended = ExitLog()
        let service = service(host, onTerminated: { ended.add($0) })
        ended.service = service
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        try await waitUntil { ended.names.contains(handle.sessionId) }
        #expect(ended.liveAtExit?.contains(handle.sessionId) == false)
    }

    /// The pane's stopped screen (issue #70) claims to appear for a terminal
    /// "stopped from its row", which is only true if `stop` reports `.terminated`
    /// the way an exit does. The store never marks a stopped row itself; this
    /// event is its only source.
    @Test func aStoppedTerminalIsReportedTerminated() async throws {
        let host = FakeSurfaceHost()
        let ended = ExitLog()
        let service = service(host, onTerminated: { ended.add($0) })
        ended.service = service
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 60", badge: nil)
        try await waitUntil { service.liveSessions.contains(handle.sessionId) }

        await service.stop(sessionId: handle.sessionId)
        try await waitUntil { ended.names.contains(handle.sessionId) }
        #expect(ended.liveAtExit?.contains(handle.sessionId) == false)
        #expect(service.jobEvents().isEmpty)
        #expect(host.destroyed.isEmpty)
    }

    /// An exited child is reaped by the service itself: it leaves the census and it
    /// stops being polled for a job.
    ///
    /// `terminals` is the source of truth for this substrate, so a corpse left in
    /// it is not a cosmetic problem: the census gates a remote viewer's attach, and
    /// an exited terminal reported as live is streamed instead of answered `ended`.
    @Test func anExitedChildLeavesTheCensusWithoutWaitingForAClose() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        _ = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                   existingWindowId: nil, command: "exit 0", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }
        #expect(liveSessionsOffTheMainActor(service).isEmpty)
        #expect(service.jobEvents().isEmpty)
    }

    /// The surface outlives the child on purpose. The last screen a command left
    /// behind is what a user wants to read when something died, and `readOutput`
    /// has to keep answering from it; only closing the row tears it down.
    ///
    /// Closing a row that was already reaped must also not free anything twice,
    /// which is the other half of what this asserts: a double `stop` or a double
    /// `terminate` would take the test host down with it rather than fail.
    @Test func anExitedTerminalKeepsItsSurfaceUntilItIsClosed() async throws {
        let host = FakeSurfaceHost()
        let service = try wiredService(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil,
                                            command: "echo died-$((20+3))", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }
        #expect(host.destroyed.isEmpty)
        let text = try await service.readOutput(sessionId: handle.sessionId, maxLines: 10)
        #expect(text == "died-23")
        try await service.close(sessionId: handle.sessionId)
        #expect(host.destroyed == [handle.sessionId])
    }

    /// libghostty asking for a surface to be closed means the terminal has ended,
    /// and is answered exactly as an exit noticed on the pty is: the pty goes, the
    /// census stops counting it, the caller is told, and the surface stays so the
    /// last screen is still readable.
    ///
    /// It reaches here when the surface's command exits, and when a `close_surface`
    /// keybinding in the user's own Ghostty configuration fires, which has no other
    /// way into the app.
    @Test func aCloseRequestFromLibghosttyRetiresTheTerminal() async throws {
        let host = FakeSurfaceHost()
        let log = TerminationLog()
        let service = service(host, onTerminated: { log.ids.append($0) })
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 30", badge: nil)
        #expect(service.liveSessions == [handle.sessionId])
        host.onCloseRequested?(handle.sessionId)
        #expect(service.liveSessions.isEmpty)
        #expect(log.ids == [handle.sessionId])
        #expect(host.destroyed.isEmpty)
    }

    /// Both halves of the same event can arrive: the shell's exit reaches the relay
    /// as EOF and reaches libghostty as its helper's child exiting. Whichever is
    /// first does the work, and the second must not report a second termination or
    /// signal a pty that is already gone.
    @Test func asecondCloseRequestIsIgnored() async throws {
        let host = FakeSurfaceHost()
        let log = TerminationLog()
        let service = service(host, onTerminated: { log.ids.append($0) })
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 30", badge: nil)
        host.onCloseRequested?(handle.sessionId)
        host.onCloseRequested?(handle.sessionId)
        #expect(log.ids == [handle.sessionId])
    }

    /// `probe` answers whether a row is alive and what it is running, and the sidebar
    /// acts on that answer. It deliberately does not move the pane: showing a terminal
    /// is a request the frontend honours, so an agent asking this question no longer
    /// moves somebody's window as a side effect. `PaneSelectionBehaviourTests` covers
    /// what the pane does.
    @Test func probeAnswersForTheRowWithoutMovingThePane() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let first = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                           existingWindowId: nil, command: "sleep 5", badge: nil)
        let second = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: "sleep 5", badge: nil)
        let result = try await service.probe(sessionId: first.sessionId)
        #expect(result.found)
        #expect(result.jobKnown)
        _ = second
    }

    /// An exited terminal is answered exactly as an absent one, which is what lets a
    /// stopped row be revived.
    ///
    /// `ProjectStore.activate` reopens whatever `focus` reports not found, and the
    /// entry here outlives its child on purpose, so answering `found: true` for a
    /// corpse left the play button on a finished Claude row doing nothing at all: the
    /// row could not reopen, and `jobKnown` was false because the master was closed,
    /// so the store had nothing to act on either. "Close terminal", which deletes the
    /// row, was the only way out.
    ///
    /// The last screen survives the answer. The whole point of keeping the surface is
    /// that a user can read what died, and a query must not be what destroys it.
    @Test func anExitedTerminalIsNotFoundSoItsRowCanReopen() async throws {
        let host = FakeSurfaceHost()
        let service = try wiredService(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil,
                                            command: "echo died-$((20+3))", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }

        let result = try await service.probe(sessionId: handle.sessionId)
        #expect(result.found == false)
        #expect(result.jobKnown == false)
        #expect(host.destroyed.isEmpty)
        #expect(try await service.readOutput(sessionId: handle.sessionId, maxLines: 10)
                == "died-23")
    }

    /// The other half of that: the reopen path frees the surface the exited entry was
    /// still holding, or a revived row costs a leaked surface and `NSView` for the
    /// life of the process.
    @Test func discardingAnExitedTerminalFreesItsSurface() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }

        await service.discard(sessionId: handle.sessionId)
        #expect(host.destroyed == [handle.sessionId])
        // And the id is gone from the registry entirely, its screen model with
        // it, so nothing is left to paint or to read from a dead terminal.
        #expect(service.screenModel(for: handle.sessionId) == nil)
        await #expect(throws: (any Error).self) {
            _ = try await service.readOutput(sessionId: handle.sessionId, maxLines: 10)
        }
    }

    /// A discard is only ever the reopen of a terminal that has stopped, so a live
    /// one is left alone. Without the guard a caller reaching here with a running
    /// terminal would turn a click on a live row into a silent close.
    @Test func discardingALiveTerminalDoesNothing() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        await service.discard(sessionId: handle.sessionId)
        #expect(service.liveSessions == [handle.sessionId])
        #expect(host.destroyed.isEmpty)
    }

    /// A keystroke for a terminal whose child has exited must be refused rather than
    /// written into a closed master, where it went nowhere and nothing said so: an
    /// MCP `send_input` and a remote keystroke both looked delivered.
    @Test func sendingToAnExitedTerminalThrows() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }
        await #expect(throws: (any Error).self) {
            try await service.send(sessionId: handle.sessionId, text: "hello\n")
        }
    }

    /// Opening a terminal registers its pty's writer, which is how a remote
    /// viewer's input reaches the master without the main actor, and closing the
    /// row takes it away with the model.
    @Test func aTerminalsWriterIsRegisteredWhileItIsOpen() async throws {
        let seen = SessionSink()
        let service = service(FakeSurfaceHost(), onOutput: { session, bytes in
            seen.append(bytes, for: session)
        })
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "cat", badge: nil)
        let writer = try #require(service.shared.writer(for: handle.sessionId))
        // A pty echoes what is written to its master, so the marker comes back
        // whether or not `cat` has started reading.
        writer(Array("written-direct\n".utf8))
        try await waitUntil { seen.text(for: handle.sessionId).contains("written-direct") }

        try await service.close(sessionId: handle.sessionId)
        #expect(service.shared.writer(for: handle.sessionId) == nil)
    }

    /// A terminal whose child exited keeps its model and its row, but not its
    /// writer: its master is closed, and input for it is refused, as `send` refuses
    /// it, rather than handed to a pty that drops it without a word.
    @Test func anExitedTerminalHasNoWriter() async throws {
        let service = service(FakeSurfaceHost())
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }
        #expect(service.shared.writer(for: handle.sessionId) == nil)
        #expect(service.screenModel(for: handle.sessionId) != nil)
    }

    /// A session id the service does not hold is not found, and reports no job
    /// rather than a wrong one.
    @Test func focusingAnUnknownSessionIsNotFound() async throws {
        let service = service(FakeSurfaceHost())
        defer { service.closeAll() }
        let result = try await service.probe(sessionId: "gt:nope")
        #expect(result.found == false)
        #expect(result.jobKnown == false)
    }

    /// Input goes to the pty master, not to the surface.
    ///
    /// This is a binding constraint of the substrate rather than an implementation
    /// detail: local keystrokes arrive through the pane's bridge onto the same master, so
    /// remote input taking the surface's own path instead would give one terminal
    /// two input paths with no ordering between them. A regression to surface-side
    /// input renders identically on screen, so nothing but this test would notice.
    ///
    /// The marker is arithmetic the shell has to evaluate. A pty echoes whatever is
    /// written to its master straight back out of it, so a literal marker would
    /// appear whether or not any shell ran the line; echo can only reproduce
    /// `$((30+5))`.
    @Test func sendWritesToThePtyMaster() async throws {
        let host = FakeSurfaceHost()
        let seen = SessionSink()
        let service = service(host, onOutput: { session, bytes in
            seen.append(bytes, for: session)
        })
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: nil, badge: nil)
        // A shell reaching its first read is not an event the test can observe, so
        // a short settle is the honest way to wait for it.
        try await Task.sleep(for: .milliseconds(600))
        try await service.send(sessionId: handle.sessionId, text: "echo sent-$((30+5))\n")
        try await waitUntil { seen.text(for: handle.sessionId).contains("sent-35") }
    }

    /// A paste into a terminal whose foreground program is not reading stdin must not
    /// freeze the app.
    ///
    /// A write to a pty master blocks once the child stops reading and the buffer
    /// fills, and this method is called on the main actor: by the remote keystroke
    /// stream, by MCP, and by the sidebar. So a `send` that performed the write here
    /// parked the whole UI until the foreground program read its input, which it need
    /// never do. Local keystrokes were never exposed to it, arriving on the relay's
    /// own queue, which is what made this look like a remote-only problem rather than
    /// a property of the write.
    ///
    /// `sleep` is the foreground program because it never reads stdin, and the paste
    /// is far past any pty input buffer, so the write is certain to park. The bound is
    /// what the assertion is: the child holds its input for five seconds, so a
    /// blocking write shows up as a test that takes that long (measured at 5.17 s
    /// against the blocking version) rather than one that hangs forever.
    ///
    /// **The newlines are load bearing.** A mebibyte of one repeated character does
    /// not block at all: BSD's `ptcwrite` parks only once the queue is full AND either
    /// the canonical queue is non-empty or the tty is non-canonical, and a canonical
    /// tty with no completed line never gets a non-empty canonical queue. So a paste
    /// of one long line proves nothing here, while a paste of lines, which is what a
    /// real paste is, parks on the first `write` that finds the queue full.
    @Test func sendDoesNotBlockOnATerminalThatIsNotReading() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        let paste = String(repeating: "line\n", count: 1 << 17)
        let started = ContinuousClock.now
        try await service.send(sessionId: handle.sessionId, text: paste)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    /// A keystroke for a terminal that is not there has to throw rather than
    /// vanish. It is the MCP path as well as the UI's, and a caller that typed
    /// into a closed row must be told.
    @Test func sendingToAnUnknownSessionThrows() async {
        let service = service(FakeSurfaceHost())
        defer { service.closeAll() }
        await #expect(throws: (any Error).self) {
            try await service.send(sessionId: "gt:nope", text: "hello\n")
        }
    }

    @Test func closingRemovesTheTerminalAndItsSurface() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        try await service.close(sessionId: handle.sessionId)
        #expect(service.liveSessions.isEmpty)
        // Destroying the surface is what stops the pane's bridge and removes its
        // socket file; `OwnPaneStreamTests` follows that through a real bridge.
        #expect(host.destroyed == [handle.sessionId])
    }

    /// `readOutput` is the MCP path: the most recent lines, capped at the number
    /// asked for, with the blank rows below the last line left off.
    @Test func readOutputReturnsTheMostRecentLines() async throws {
        let host = FakeSurfaceHost()
        let service = try wiredService(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil,
                                            command: #"printf 'one\ntwo\nthree-%s\n' $((1+2)); sleep 5"#,
                                            badge: nil)
        try await waitUntil {
            service.screenModel(for: handle.sessionId)?.text(maxLines: 10).contains("three-3") ?? false
        }
        #expect(try await service.readOutput(sessionId: handle.sessionId, maxLines: 10)
                == "one\ntwo\nthree-3")
        #expect(try await service.readOutput(sessionId: handle.sessionId, maxLines: 2)
                == "two\nthree-3")
    }

    /// The protocol requires a throw for a session that is not there, and MCP
    /// consumers rely on it to tell "empty terminal" from "no such terminal".
    @Test func readOutputThrowsForAnUnknownSession() async {
        let service = service(FakeSurfaceHost())
        defer { service.closeAll() }
        await #expect(throws: (any Error).self) {
            _ = try await service.readOutput(sessionId: "gt:nope", maxLines: 10)
        }
    }

    /// A terminal that is not on screen reads in full, scrollback included.
    ///
    /// This is the read an agent makes, since the session it asks about is almost
    /// never the one pane the window shows. A surface answers nothing for a
    /// terminal that is not displayed, so this used to come back as one recorded
    /// viewport however many lines were asked for. Nothing here is displayed at
    /// all: the host is a fake with no window, and the answer still reaches two
    /// hundred lines up, on a grid of thirty four rows.
    @Test func readOutputReachesScrollbackForATerminalThatIsNotDisplayed() async throws {
        let host = FakeSurfaceHost()
        let service = try wiredService(host)
        defer { service.closeAll() }
        let handle = try await service.open(
            folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
            command: "i=0; while [ $i -lt 300 ]; do i=$((i+1)); echo row-$i; done; sleep 5",
            badge: nil)
        try await waitUntil {
            service.screenModel(for: handle.sessionId)?.text(maxLines: 1).contains("row-300") ?? false
        }
        let text = try await service.readOutput(sessionId: handle.sessionId, maxLines: 200)
        #expect(text.components(separatedBy: "\n") == (101...300).map { "row-\($0)" })
    }

    /// The surface's grid is the sizing authority: a resize reported by
    /// libghostty has to reach the pty, or a full screen program keeps drawing
    /// for the old size.
    ///
    /// The child loops over a short sleep rather than sitting in a long one. A
    /// shell defers a trap until the foreground command it is waiting on returns,
    /// measured at 4.2 s for `sleep 5`, which is most of this test's budget spent
    /// proving nothing about the resize.
    @Test func aSurfaceResizeReachesThePty() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let probe = NSTemporaryDirectory() + "ipx-resize-\(UInt32.random(in: 0..<0xFFFFFF))"
        defer { try? FileManager.default.removeItem(atPath: probe) }
        let handle = try await service.open(
            folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
            command: "trap 'stty size > \(probe)' WINCH; while true; do sleep 0.2; done",
            badge: nil)
        try await Task.sleep(for: .milliseconds(600))
        // Nothing has resized this terminal yet, so a probe file here would mean
        // the assertion below could pass on a stale reading.
        #expect(FileManager.default.fileExists(atPath: probe) == false)
        host.emitResize(handle.sessionId, TerminalSize(cols: 111, rows: 41))
        try await waitUntil {
            (try? String(contentsOfFile: probe, encoding: .utf8))?.contains("41 111") ?? false
        }
    }

    /// The polled job, per live terminal. A terminal whose query fails emits no
    /// event at all rather than an empty name, because `ProjectStore.runState`
    /// treats a job it has never been told as unknown and that is the correct
    /// reading of a failed query.
    @Test func jobEventsCoverEveryLiveTerminal() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        try await waitUntil {
            service.jobEvents().contains(.job(sessionId: handle.sessionId, jobName: "sleep"))
        }
    }

    /// Records `onTerminated`'s argument, and what the census said at the moment
    /// it was called.
    ///
    /// The callback is stored and called back later, so a captured local `var`
    /// would be a box mutated from a closure the test no longer owns; this keeps
    /// the recording in one place. The service reference is weak and assigned
    /// after construction, because the callback has to exist before the service
    /// that calls it does.
    @MainActor
    private final class ExitLog {
        weak var service: GhosttyService?
        private(set) var names: [String] = []
        /// `liveSessions` as read from inside the handler.
        private(set) var liveAtExit: Set<String>?
        func add(_ name: String) {
            names.append(name)
            liveAtExit = service?.liveSessions
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
