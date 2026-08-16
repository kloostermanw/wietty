import Testing
import Foundation
import Darwin
@testable import Wietty

/// Lock-guarded accumulator, not a captured `var`: the output handler is
/// `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a captured
/// local. The same shape `RawPTYTests`, `TerminalRelayTests` and
/// `PaneStreamHubTests` each keep for the same reason; it is file private here
/// because theirs are private to their own suites.
private final class TextSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    var text: String { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ bytes: [UInt8]) {
        lock.lock(); storage += String(decoding: bytes, as: UTF8.self); lock.unlock()
    }
}

/// The same, keyed by session, for the output callback that carries one.
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

/// Reads whatever is available on `fd` within `timeout`, without blocking past
/// it. `FileHandle.availableData` blocks until something arrives, so a poll loop
/// built on it turns a failing test into a hung one.
private func readAvailable(_ fd: Int32, timeout: Int32 = 100) -> [UInt8] {
    var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&readable, 1, timeout) > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { return [] }
    return Array(buffer[0..<count])
}

@MainActor
@Suite struct GhosttyServiceTests {
    private func service(_ host: FakeSurfaceHost,
                         onOutput: @escaping @Sendable (String, [UInt8]) -> Void = { _, _ in },
                         onTerminated: @escaping @MainActor (String) -> Void = { _ in })
        -> GhosttyService {
        GhosttyService(host: host, helperPath: "/usr/bin/true",
                       onOutput: onOutput, onTerminated: onTerminated)
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

    /// The surface's command is the bundled helper pointed at this terminal's
    /// socket, never the user's shell. libghostty spawning the shell itself is
    /// exactly what this substrate exists to avoid, because then Wietty owns
    /// no byte stream and no remote viewer can be served.
    @Test func theSurfaceRunsTheHelperNotTheShell() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: nil, badge: nil)
        let command = try #require(host.commands[handle.sessionId])
        #expect(command.hasPrefix("/usr/bin/true "))
        #expect(command.contains(".sock"))
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
    /// the shell keeps running with no renderer and no way to reach it, and the
    /// socket file stays in the temp directory.
    @Test func aFailedSurfaceLeavesNoTerminal() async {
        let host = FakeSurfaceHost()
        host.failNextCreate = true
        let service = service(host)
        defer { service.closeAll() }
        await #expect(throws: (any Error).self) {
            _ = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                        existingWindowId: nil, command: nil, badge: nil)
        }
        #expect(service.liveSessions.isEmpty)
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

    /// `.terminated` has only one source on this substrate: the child exiting.
    /// Without it a finished row stays marked running for the life of the app.
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

    /// An exited child is reaped by the service itself: it leaves the census, it
    /// stops being polled for a job, and its socket file goes.
    ///
    /// `terminals` is the source of truth for this substrate, so a corpse left in
    /// it is not a cosmetic problem: the census gates a remote viewer's attach, and
    /// an exited terminal reported as live is streamed instead of answered `ended`.
    @Test func anExitedChildLeavesTheCensusWithoutWaitingForAClose() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        let command = try #require(host.commands[handle.sessionId])
        let socket = try #require(command.components(separatedBy: " ").last)
        try await waitUntil { service.liveSessions.isEmpty }
        #expect(liveSessionsOffTheMainActor(service).isEmpty)
        #expect(service.jobEvents().isEmpty)
        #expect(FileManager.default.fileExists(atPath: socket) == false)
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
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["died here"], cols: 80)
        try await waitUntil { service.liveSessions.isEmpty }
        #expect(host.destroyed.isEmpty)
        let text = try await service.readOutput(sessionId: handle.sessionId, maxLines: 10)
        #expect(text == "died here")
        try await service.close(sessionId: handle.sessionId)
        #expect(host.destroyed == [handle.sessionId])
    }

    /// Output is what brings the paint up to date, within `snapshotDebounce`.
    ///
    /// The bound matters more than the mechanism. Recording only on a resize and a
    /// selection change left a viewer attaching to a freshly opened terminal painted
    /// an empty grid; recording on the monitor poll instead left it painted a screen
    /// up to five minutes old, because that poll runs at 15 seconds with a workspace
    /// expanded and 300 with every one collapsed. Neither is visible in a test that
    /// only calls `refreshSnapshots` by hand, which is why this one goes through real
    /// terminal output.
    @Test func outputRefreshesTheSnapshotWithoutWaitingForThePoll() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: nil, badge: nil)
        // Scripted after the open, so the record `select` already did cannot be what
        // satisfies this: at that point the host had no screen to give.
        #expect(service.shared.snapshot(for: handle.sessionId) == nil)
        host.sizes[handle.sessionId] = TerminalSize(cols: 80, rows: 24)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["fresh"], cols: 80)
        // The shell echoes this, which is output arriving on the relay's queue.
        try await service.send(sessionId: handle.sessionId, text: "echo marker\n")
        try await waitUntil { service.shared.snapshot(for: handle.sessionId)?.rows == ["fresh"] }
        // The grid's own height, not a larger number: this runs while output flows.
        #expect(host.requestedMaxLines[handle.sessionId] == 24)
    }

    /// A closed terminal is not recorded against, however late its last bytes land.
    /// A snapshot left behind would paint a dead screen for an id the app may mint
    /// again, which is the reason `close` clears it.
    @Test func outputArrivingAfterACloseRecordsNothing() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: nil, badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["too late"], cols: 80)
        // Marked as though a chunk arrived, then closed before the refresh runs.
        service.noteOutput(handle.sessionId)
        try await service.close(sessionId: handle.sessionId)
        try await Task.sleep(for: .milliseconds(600))
        #expect(service.shared.snapshot(for: handle.sessionId) == nil)
    }

    /// The paint a remote viewer attaches to has to be current, and a resize and a
    /// selection change are not enough to make it so: a terminal opened and then
    /// attached to from a browser has had neither since its shell printed anything,
    /// so without this the viewer's first frame is the empty screen from the instant
    /// the surface was created. Measured against a running instance before the fix:
    /// the paint was a clear-screen and a row count of zero.
    @Test func refreshingSnapshotsRerecordsEveryLiveTerminal() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 30", badge: nil)
        // The screen the shell printed after the surface was created, which nothing
        // has recorded yet.
        host.sizes[handle.sessionId] = TerminalSize(cols: 80, rows: 24)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["a prompt"], cols: 80)
        service.refreshSnapshots()
        #expect(service.shared.snapshot(for: handle.sessionId)?.rows == ["a prompt"])
        // The grid's own height, not a larger fixed number: this runs on every poll
        // and reaching scrollback costs 34 ms against 0.14 ms for the viewport.
        #expect(host.requestedMaxLines[handle.sessionId] == 24)
    }

    /// An exited terminal is skipped, so whatever was recorded while it was alive is
    /// left exactly as it was. Its screen cannot change again, and a viewer attaching
    /// to it is answered `ended` by the census rather than painted at all, so a
    /// refresh here would be work whose result nothing can read.
    @Test func refreshingSnapshotsSkipsAnExitedTerminal() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        try await waitUntil { service.liveSessions.isEmpty }
        // Scripted only after the exit, so picking it up is proof the terminal was
        // read rather than skipped.
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["never recorded"], cols: 80)
        service.refreshSnapshots()
        #expect(service.shared.snapshot(for: handle.sessionId) == nil)
    }

    /// libghostty asking for a surface to be closed means the terminal has ended,
    /// and is answered exactly as an exit noticed on the relay is: the pty goes, the
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

    /// `focus` on this substrate means "show this row in the pane". It also has to
    /// answer the job question, because the sidebar acts on it.
    @Test func focusSelectsTheRow() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let first = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                           existingWindowId: nil, command: "sleep 5", badge: nil)
        let second = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                             existingWindowId: nil, command: "sleep 5", badge: nil)
        #expect(service.selected == second.sessionId)
        let result = try await service.focus(sessionId: first.sessionId)
        #expect(result.found)
        #expect(service.selected == first.sessionId)
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
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "exit 0", badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["died here"], cols: 80)
        try await waitUntil { service.liveSessions.isEmpty }

        let result = try await service.focus(sessionId: handle.sessionId)
        #expect(result.found == false)
        #expect(result.jobKnown == false)
        #expect(host.destroyed.isEmpty)
        #expect(try await service.readOutput(sessionId: handle.sessionId, maxLines: 10)
                == "died here")
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
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["died here"], cols: 80)
        try await waitUntil { service.liveSessions.isEmpty }

        await service.discard(sessionId: handle.sessionId)
        #expect(host.destroyed == [handle.sessionId])
        // And the id is gone from the registry entirely, so an attach to it is
        // answered `ended` rather than painted from a dead screen.
        #expect(service.shared.snapshot(for: handle.sessionId) == nil)
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

    /// A session id the service does not hold is not found, and reports no job
    /// rather than a wrong one.
    @Test func focusingAnUnknownSessionIsNotFound() async throws {
        let service = service(FakeSurfaceHost())
        defer { service.closeAll() }
        let result = try await service.focus(sessionId: "gt:nope")
        #expect(result.found == false)
        #expect(result.jobKnown == false)
    }

    /// Input goes to the pty master, not to the surface.
    ///
    /// This is a binding constraint of the substrate rather than an implementation
    /// detail: local keystrokes arrive through the relay onto the same master, so
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

    /// A resize records the shared snapshot at the surface's own row count, never
    /// at a fixed larger number.
    ///
    /// The number asked for is the contract, not just the rows that come back:
    /// `read_text` reaching into scrollback measures roughly 34 ms on the main
    /// actor against 0.14 ms for the viewport, and this runs on every notch of a
    /// window drag. A grid of 24 is neither the substrate's initial 34 nor any
    /// plausible constant, so a regression to one shows up here.
    @Test func aResizeRecordsTheSnapshotAtTheGridsOwnHeight() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: (1...40).map { "row \($0)" },
                                                          cols: 90)
        host.emitResize(handle.sessionId, TerminalSize(cols: 90, rows: 24))
        #expect(host.requestedMaxLines[handle.sessionId] == 24)
        // And the result is what the hub will paint from.
        let recorded = try #require(service.shared.snapshot(for: handle.sessionId))
        #expect(recorded.rows.count == 24)
        #expect(recorded.rows.last == "row 40")
    }

    @Test func closingRemovesTheTerminalAndItsSurface() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        let command = try #require(host.commands[handle.sessionId])
        let socket = try #require(command.components(separatedBy: " ").last)
        try await service.close(sessionId: handle.sessionId)
        #expect(service.liveSessions.isEmpty)
        #expect(host.destroyed == [handle.sessionId])
        // The relay's socket file goes with it. A close that left it behind would
        // leak one file per terminal for the life of the login session.
        #expect(FileManager.default.fileExists(atPath: socket) == false)
    }

    /// `readOutput` is the MCP path and the one place the plain text limitation
    /// costs nothing.
    @Test func readOutputReturnsTheSnapshotRows() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["one", "two", "three"], cols: 80)
        let text = try await service.readOutput(sessionId: handle.sessionId, maxLines: 2)
        #expect(text == "two\nthree")
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

    /// A terminal that is not the on-screen pane reads empty from the live surface:
    /// libghostty's `read_text` returns nothing while a surface is off-screen. That
    /// is the case for every MCP read, since the session read is almost never the one
    /// pane the window shows, so `readOutput` must answer from the screen recorded
    /// from the terminal's own output rather than return an empty string.
    @Test func readOutputFallsBackToTheRecordedScreenWhenTheSurfaceIsOffScreen() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        // The output path recorded a screen while the surface was still readable.
        host.sizes[handle.sessionId] = TerminalSize(cols: 80, rows: 24)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["prompt$ echo hi", "hi"], cols: 80)
        service.refreshSnapshots()
        try #require(service.shared.snapshot(for: handle.sessionId)?.rows == ["prompt$ echo hi", "hi"])

        // Now it is off-screen: the live read gives nothing, as libghostty's does for
        // a surface that is not the displayed pane.
        host.snapshots[handle.sessionId] = nil
        host.sizes[handle.sessionId] = nil

        let text = try await service.readOutput(sessionId: handle.sessionId, maxLines: 50)
        #expect(text == "prompt$ echo hi\nhi")
    }

    /// Recording a screen never replaces a real one with a blank. A surface reads
    /// empty the moment it leaves the screen, and output arriving right then would
    /// otherwise record that blank over what the terminal printed, which is exactly
    /// what `readOutput` then falls back to. Only `close` and `reap` clear a recorded
    /// screen, and they do so directly.
    @Test func recordingDoesNotReplaceARecordedScreenWithABlankOne() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let handle = try await service.open(folder: URL(fileURLWithPath: "/tmp"),
                                            existingWindowId: nil, command: "sleep 5", badge: nil)
        host.sizes[handle.sessionId] = TerminalSize(cols: 80, rows: 24)
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: ["real output"], cols: 80)
        service.refreshSnapshots()
        try #require(service.shared.snapshot(for: handle.sessionId)?.rows == ["real output"])

        // Off-screen now: the live read is a blank screen, not nil.
        host.snapshots[handle.sessionId] = ScreenSnapshot(rows: [], cols: 80)
        service.refreshSnapshots()

        #expect(service.shared.snapshot(for: handle.sessionId)?.rows == ["real output"])
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

/// The real relay and the real bundled helper, talking to each other over a real
/// socket, with a real shell behind the pty.
///
/// Every other test of this path fakes one side. This one fakes neither, because
/// the seam between them is exactly where a wrong assumption survives two green
/// suites: the relay's tests would still pass against a helper that never sets raw
/// mode, and the helper's tests would still pass against a relay that never drains
/// its pre-connect backlog.
@Suite struct RelayHelperIntegrationTests {
    /// The same lookup `WiettyPtyHelperTests` uses; see `bundledHelperURL`.
    private func helperURL() throws -> URL { try bundledHelperURL() }

    /// Output reaches the helper's stdout, which in the app is the surface's pty.
    /// The marker is computed by the shell so the pty's own echo cannot satisfy it.
    @Test func aShellsOutputReachesTheHelper() throws {
        let path = try TerminalRelay.socketPath(for: "gt:" + UUID().uuidString)
        let pty = try RawPTY.spawn(command: "echo bridged-$((60+3))",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:],
                                   size: TerminalSize(cols: 80, rows: 24))
        let relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
        defer { relay.stop(); pty.terminate() }
        relay.start(onExit: { _ in })

        let helper = Process()
        helper.executableURL = try helperURL()
        helper.arguments = [path]
        let fromHelper = Pipe()
        helper.standardOutput = fromHelper
        helper.standardInput = Pipe()
        try helper.run()
        defer { helper.terminate() }

        let deadline = Date().addingTimeInterval(8)
        var seen = ""
        while Date() < deadline, !seen.contains("bridged-63") {
            seen += String(decoding: readAvailable(fromHelper.fileHandleForReading.fileDescriptor),
                           as: UTF8.self)
        }
        #expect(seen.contains("bridged-63"))
    }

    /// Input written to the helper's stdin reaches the shell and is executed, and
    /// the same bytes reach `onOutput`, which is what feeds every remote viewer.
    /// One assertion for each, because a relay that fed only one of them would be
    /// invisible to the other side's suite.
    ///
    /// `bridged-77` is arithmetic the shell has to evaluate. A pty echoes whatever
    /// is written to its master straight back out of it, so a literal marker would
    /// be produced by the echo alone whether or not any shell ran the line; the
    /// echo can only ever reproduce `$((70+7))`.
    @Test func inputThroughTheHelperReachesTheShellAndTheStream() throws {
        let path = try TerminalRelay.socketPath(for: "gt:" + UUID().uuidString)
        let pty = try RawPTY.spawn(command: nil, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24))
        let streamed = TextSink()
        let relay = try TerminalRelay(pty: pty, socketPath: path) { bytes in
            streamed.append(bytes)
        }
        defer { relay.stop(); pty.terminate() }
        relay.start(onExit: { _ in })

        let helper = Process()
        helper.executableURL = try helperURL()
        helper.arguments = [path]
        let toHelper = Pipe()
        let fromHelper = Pipe()
        helper.standardInput = toHelper
        helper.standardOutput = fromHelper
        try helper.run()
        defer { helper.terminate() }

        Thread.sleep(forTimeInterval: 1.0)
        toHelper.fileHandleForWriting.write(Data("echo bridged-$((70+7))\n".utf8))

        // The helper's stdout is drained in the same loop rather than on a second
        // thread: a pipe nobody reads eventually fills and parks the helper.
        let deadline = Date().addingTimeInterval(8)
        var rendered = ""
        while Date() < deadline,
              !(rendered.contains("bridged-77") && streamed.text.contains("bridged-77")) {
            rendered += String(
                decoding: readAvailable(fromHelper.fileHandleForReading.fileDescriptor, timeout: 50),
                as: UTF8.self)
        }
        #expect(streamed.text.contains("bridged-77"))
        #expect(rendered.contains("bridged-77"))
    }
}
