import Foundation

/// The parts of the terminal registry `PaneStreamHub` reads, behind a lock rather
/// than the main actor.
///
/// The hub asks two questions from its own delivery queue, and neither can wait
/// for a hop to the main actor. The census gates an attach, which has to be
/// answered before the viewer is registered. The paint has to be ordered against
/// the flush that carries the bytes produced while it ran, and that ordering is
/// the delivery queue's. Hopping either would put a viewer's first frame behind
/// whatever the UI is doing.
///
/// The cost is that the paint is as fresh as the last recorded snapshot rather
/// than the instant of attach. `GhosttyService` records on every resize and every
/// selection change, which is when the screen a viewer would want has changed
/// shape; between those, the live byte stream is what keeps a viewer current.
final class SharedTerminalState: @unchecked Sendable {
    private let lock = NSLock()
    private var live: Set<String> = []
    private var snapshots: [String: ScreenSnapshot] = [:]

    var liveSessions: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    func note(live sessions: Set<String>) {
        lock.lock(); live = sessions; lock.unlock()
    }

    func record(_ snapshot: ScreenSnapshot?, for session: String) {
        lock.lock(); snapshots[session] = snapshot; lock.unlock()
    }

    func snapshot(for session: String) -> ScreenSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[session]
    }
}

/// Which terminals have printed something since their screen was last recorded,
/// and whether a refresh is already on its way.
///
/// Lock guarded rather than actor isolated because it is marked from the relay's
/// own queue, where every byte of terminal output arrives, and read on the main
/// actor where the surface can be asked for a screen. Hopping to the main actor per
/// chunk of output is exactly what the byte path exists to avoid.
final class SnapshotBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty: Set<String> = []
    private var scheduled = false

    /// Marks a session dirty, and answers whether the caller now owns scheduling
    /// the refresh. True exactly once per window, so a terminal printing a
    /// megabyte schedules one refresh rather than one per chunk.
    func note(_ session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        dirty.insert(session)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Takes the dirty set and reopens the window, in one step: a session marked
    /// after this returns belongs to the next refresh rather than being dropped.
    func drain() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let sessions = dirty
        dirty = []
        scheduled = false
        return sessions
    }
}

/// The libghostty substrate's `TerminalService`.
///
/// A terminal here is three things that live and die together: a `RawPTY` running
/// the user's shell, a `TerminalRelay` carrying its bytes, and a libghostty
/// surface rendering them. This type is what keeps the three in step, and it is
/// the only place that knows a terminal is not a single object.
///
/// A session id is minted here (`gt:<uuid>`) rather than taken from a substrate,
/// because there is no substrate to ask: the PTY belongs to the app.
///
/// Main actor isolated, because the surface host is. The byte path is not: it
/// runs on the relay's own queues and touches only `PaneStreamHub`, which is
/// lock protected. That split is deliberate. Hopping every chunk of terminal
/// output to the main actor would put a shell's output behind the UI's work.
@MainActor
final class GhosttyService: TerminalService {
    private struct Terminal {
        let pty: RawPTY
        let relay: TerminalRelay
        /// Whether the child has exited and been reaped. The entry outlives the
        /// child on purpose: the surface, and so the last screen the command left
        /// behind, is kept until the row is closed or reopened.
        ///
        /// Everything that acts on a terminal has to consult this, because an
        /// entry that is still here says nothing about whether there is a terminal
        /// left to act on. `focus` answers not-found for one, so the row reopens on
        /// a click exactly as it does on the other two substrates, and `send`
        /// throws rather than writing into a closed master. `discard` is what frees
        /// the surface at the moment of that reopen.
        var exited = false
    }

    private let host: any TerminalSurfaceHosting
    private let helperPath: String
    private let shell: String
    private let onOutput: @Sendable (String, [UInt8]) -> Void
    /// A terminal's grid changed. Mirrors `onOutput`: the substrate reports, and
    /// `GhosttyStack` decides that the hub is what hears it.
    ///
    /// Defaulted to nothing, because a grid report is not part of running a
    /// terminal: the pty is resized either way, and a service built without a
    /// remote path simply has nobody to tell.
    private let onResized: @Sendable (String, TerminalSize) -> Void
    /// A terminal's byte stream is over: no further output will ever be reported
    /// for this session id, whether because the child exited or because the row was
    /// closed.
    ///
    /// Separate from `onTerminated`, which is the sidebar's event and fires only on
    /// an exit. This one exists for the viewers of the stream, who have to be told
    /// in both cases: `PaneStreamHub` gates an attach on the census, but an already
    /// attached browser or iPad has nothing else to learn it from and would sit on
    /// a socket that never speaks again. The service is the only thing that knows.
    ///
    /// Defaulted to nothing, for the same reason `onResized` is: a service built
    /// with no remote path has nobody to tell.
    private let onStreamEnded: @Sendable (String) -> Void
    private let onTerminated: @MainActor (String) -> Void
    private var terminals: [String: Terminal] = [:]

    /// The terminal the pane shows. Only one surface is in the window's view
    /// hierarchy at a time; the rest stay alive and keep reading.
    private(set) var selected: String?
    var onSelectionChanged: (@MainActor (String?) -> Void)?

    /// The registry as `PaneStreamHub` sees it, off the main actor.
    ///
    /// `nonisolated` rather than plain `let`, and it has to be: the hub reads this
    /// from its own delivery queue, so an access that needed a hop to the main
    /// actor would not compile there at all.
    nonisolated let shared = SharedTerminalState()

    /// Terminals that have printed since their screen was recorded.
    ///
    /// `nonisolated` and lock guarded, and it has to be: it is marked from the
    /// relay's queue as output arrives.
    nonisolated let backlog = SnapshotBacklog()

    /// How long a burst of output is allowed to run before the screen a remote
    /// viewer would be painted from is brought up to date.
    ///
    /// This is the paint's staleness bound, so it is the number that matters.
    /// Long enough that a terminal printing continuously coalesces into a handful
    /// of reads per second rather than one per chunk, and short enough that a
    /// viewer attaching a moment after a command finished sees that command's
    /// output. A viewport read costs 0.14 ms, so even at one refresh per interval
    /// per terminal this is not measurable.
    /// `nonisolated` because the scheduling that reads it happens on the relay's
    /// queue, and an immutable interval needs no isolation to be read safely.
    nonisolated static let snapshotDebounce: TimeInterval = 0.3

    /// What every session id this app mints starts with.
    ///
    /// One definition, because two things read it: `open`, which mints them, and
    /// `ProjectStore.clearDeadSessions`, which is how the launch wipe tells an id
    /// this build could have minted from a leftover written by an older one.
    ///
    /// `nonisolated` because the store answers that question from its own
    /// `@MainActor` context and a test may ask from anywhere; an immutable string
    /// needs no isolation to be read.
    nonisolated static let sessionPrefix = "gt:"

    /// The size a terminal starts at, before any surface has been laid out. A
    /// terminal has to be spawned with some grid, and a full screen program lays
    /// itself out from what it finds; the first `onResized` corrects it.
    static let initialSize = TerminalSize(cols: 120, rows: 34)

    /// The terminals whose child is still running. A reaped one is deliberately
    /// absent: this is the census a remote viewer's attach is gated on, and an
    /// exited terminal must be answered `ended` rather than streamed.
    var liveSessions: Set<String> {
        Set(terminals.lazy.filter { !$0.value.exited }.map(\.key))
    }

    init(host: any TerminalSurfaceHosting,
         helperPath: String,
         shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
         onOutput: @escaping @Sendable (String, [UInt8]) -> Void,
         onResized: @escaping @Sendable (String, TerminalSize) -> Void = { _, _ in },
         onStreamEnded: @escaping @Sendable (String) -> Void = { _ in },
         onTerminated: @escaping @MainActor (String) -> Void) {
        self.host = host
        self.helperPath = helperPath
        self.shell = shell
        self.onOutput = onOutput
        self.onResized = onResized
        self.onStreamEnded = onStreamEnded
        self.onTerminated = onTerminated
        host.onResized = { [weak self] session, size in
            guard let self else { return }
            // Only for a terminal this service holds. A report for anything else
            // names no pty to resize and no screen worth telling a viewer about.
            guard let terminal = self.terminals[session] else { return }
            terminal.pty.resize(to: size)
            // A reflow rewrites the screen a viewer attaching next would want, so
            // this is one of the two moments the shared snapshot is refreshed.
            self.recordSnapshot(session)
            // And only AFTER that snapshot, because this is what makes an already
            // attached viewer repaint: told first, the repaint would read the screen
            // as it was before the reflow and then be contradicted by the bytes the
            // reflow produced.
            self.onResized(session, size)
        }
        // libghostty asking for a surface to be closed means the terminal has
        // ended, so it is retired exactly as an exit noticed on the relay is. The
        // two paths are the same event seen from either side: the user's `exit`
        // reaches the relay as EOF and reaches libghostty as its helper's child
        // exiting, and whichever arrives first does the work because `reap` is
        // guarded. It also covers a `close_surface` keybinding in the user's own
        // Ghostty configuration, which has no other way in.
        host.onCloseRequested = { [weak self] session in self?.reap(session) }
    }

    /// Records the screen the hub paints from, whatever the host answers.
    ///
    /// Not monotonic, and nothing downstream may assume it is: a host that answers
    /// nil, which it does for a surface with no grid yet, overwrites a good screen
    /// with nothing. The hub reads that as a capture that failed rather than as an
    /// empty screen, so the viewer keeps whatever it had and the live bytes bring it
    /// current. That is the honest reading, and keeping the older screen instead
    /// would mean painting a viewer a state the terminal has since left.
    ///
    /// Asks for the grid's own height, never a fixed larger number. A paint wants
    /// the visible screen, and `read_text` reaching into scrollback is not free:
    /// measured at roughly 29 ms in the call plus 5 ms to decode, against 0.14 ms
    /// for the viewport, all on the main actor. Asking for more rows than the grid
    /// has turns every notch of a window drag into a 34 ms stall.
    ///
    /// That saving depends on the host treating exactly the grid's height as the
    /// viewport read, which is the boundary `GhosttySurfaceHost.readsScrollback`
    /// exists to pin. It was `>=` there once, so this call, the most frequent one in
    /// the substrate, took the whole screen path every time and this comment
    /// described a saving that was not happening.
    private func recordSnapshot(_ session: String) {
        let rows = host.size(id: session)?.rows ?? Self.initialSize.rows
        let fresh = host.snapshot(id: session, maxLines: rows)
        // A blank read never replaces a screen already recorded. libghostty reads a
        // surface as empty the instant it leaves the screen, and output arriving then
        // would otherwise record that blank over what the terminal printed, which is
        // what `readOutput` falls back to for every off-screen (so every MCP) read.
        // A live screen always has at least its prompt row, so an empty read is the
        // off-screen case rather than a genuinely cleared screen. Clearing a recorded
        // screen is left to `close`/`discard` (via `tearDown`) and `closeAll`, which
        // record `nil` directly; `reap` deliberately keeps the screen so a terminal
        // stays readable after its child exits.
        if fresh?.rows.isEmpty ?? true, let existing = shared.snapshot(for: session),
           !existing.rows.isEmpty {
            return
        }
        shared.record(fresh, for: session)
    }

    /// Notes that a terminal printed something, and schedules the refresh that keeps
    /// a remote viewer's first frame honest.
    ///
    /// Output is what this is driven from, because output is the only thing that
    /// changes a screen. A resize and a selection change are the two moments a screen
    /// changes *shape*, and for a while they were the only moments the screen was
    /// recorded at all: a terminal opened and then attached to from a browser had had
    /// neither since its shell printed anything, so the viewer was painted the empty
    /// screen from the instant the surface was created. Measured against a running
    /// instance, that paint was `ESC[2J ESC[H` and a row count of zero.
    ///
    /// The monitor poll was the first fix and was not good enough. That poll is the
    /// app wide job check, whose interval is 15 seconds when a workspace is expanded
    /// and 300 when every one is collapsed, so a viewer could be shown a screen five
    /// minutes old and only then start receiving live bytes, with everything between
    /// missing from its first frame. Bounding the staleness at
    /// `snapshotDebounce` instead makes it a property of this type rather than of an
    /// unrelated setting.
    ///
    /// `nonisolated`, because it is called from the relay's queue as the bytes
    /// arrive. Only the scheduling happens there; the read itself is main actor work.
    nonisolated func noteOutput(_ session: String) {
        guard backlog.note(session) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.snapshotDebounce) { [weak self] in
            MainActor.assumeIsolated { self?.refreshSnapshots(self?.backlog.drain() ?? []) }
        }
    }

    /// Refreshes the snapshot of every live terminal.
    ///
    /// The backstop, called once per monitor poll from `GhosttyStack.storeSubstrate`.
    /// `noteOutput` is what bounds the staleness in practice; this covers an idle
    /// terminal whose screen was changed by something other than its own output,
    /// which is cheaper than reasoning about whether such a case exists.
    func refreshSnapshots() {
        refreshSnapshots(Set(terminals.keys))
    }

    /// Cheap on purpose. Each read asks for the grid's own height, which is the
    /// viewport read at roughly 0.14 ms rather than the whole screen read at 34 ms,
    /// so a workspace of eight terminals costs about a millisecond. Cheap only while
    /// the host reads that boundary as the viewport; see `recordSnapshot`.
    ///
    /// An exited terminal is skipped, and one that has been closed is simply absent:
    /// its screen cannot change again, a viewer attaching to it is answered `ended`
    /// by the census rather than painted, and recording against an id the app may
    /// mint again is how a dead screen ends up under a live terminal.
    private func refreshSnapshots(_ sessions: Set<String>) {
        for session in sessions where terminals[session].map({ !$0.exited }) == true {
            recordSnapshot(session)
        }
    }

    func open(folder: URL, existingWindowId: String?, command: String?,
              badge: String?) async throws -> TerminalHandle {
        let session = Self.sessionPrefix + UUID().uuidString.lowercased()
        let socketPath = try TerminalRelay.socketPath(for: session)
        let pty = try RawPTY.spawn(command: command, directory: folder, environment: [:],
                                   size: Self.initialSize, shell: shell)
        let onOutput = self.onOutput
        let relay: TerminalRelay
        do {
            relay = try TerminalRelay(pty: pty, socketPath: socketPath) { [weak self] bytes in
                // The hub first and unconditionally: a live viewer's bytes must not
                // wait behind anything, and this runs on the relay's queue precisely
                // so they do not.
                onOutput(session, bytes)
                // Then note that the screen moved, which is what keeps the paint a
                // viewer attaching *next* is built from within `snapshotDebounce` of
                // the truth. Weakly, so a service that is gone cannot be resurrected
                // by a relay still draining.
                self?.noteOutput(session)
            }
        } catch {
            // Nothing is registered yet, so nothing else will clean this up.
            pty.terminate()
            throw error
        }

        // The surface's command is the helper, never the user's shell. libghostty
        // spawning the shell is exactly what this substrate exists to avoid,
        // because then Wietty owns no byte stream and no remote viewer can be
        // served.
        //
        // `badge` travels as the surface's title. libghostty has no title setter,
        // so today it reaches the host's own record and the view's accessibility
        // label and no further: it labels nothing a sighted user can see. It is
        // still passed rather than dropped, because the alternative is a substrate
        // that silently ignores a workspace setting the other two honour, and the
        // day the C API grows a setter this already carries the value.
        do {
            try host.createSurface(id: session,
                                   command: "\(helperPath) \(socketPath)",
                                   directory: folder,
                                   title: badge)
        } catch {
            relay.stop()
            pty.terminate()
            throw error
        }

        relay.start(onExit: { [weak self] _ in
            Task { @MainActor in self?.reap(session) }
        })
        terminals[session] = Terminal(pty: pty, relay: relay)
        shared.note(live: liveSessions)
        select(session)

        // `windowId` is echoed back rather than minted. Nothing here is a window,
        // and `ProjectStore.recordWorkspaceId` writes whatever comes back onto
        // `Project.windowId`, so minting a value would invent a name nothing reads.
        return TerminalHandle(sessionId: session, windowId: existingWindowId ?? "")
    }

    /// Retires a terminal whose child has exited: the relay and the pty go, the
    /// census stops counting it, and only then is the caller told.
    ///
    /// The service reaps itself rather than leaving it to whoever wired the
    /// callback. `terminals` is the source of truth, so a corpse left in it is a
    /// broken invariant inside the one type that owns
    /// it: the census reports a dead terminal as attachable, `jobEvents` polls a
    /// closed master, and the relay's socket file survives until someone
    /// remembers to call `close`. Requiring every future construction of this
    /// service to remember that wiring is exactly the seam that gets forgotten.
    ///
    /// The order matters. The viewers are told, and then `onTerminated` last, so a
    /// handler that asks `liveSessions` what is running never sees the terminal it
    /// is being told about.
    ///
    /// The surface is deliberately NOT destroyed. The last screen the command left
    /// behind is what a user wants to read when something died, and `readOutput`
    /// keeps working on it; `close`, `discard` and `closeAll` are what tear it
    /// down. Guarded by `exited`, because the child can be reaped once and closed
    /// later and neither may free anything twice.
    private func reap(_ session: String) {
        guard let terminal = terminals[session], !terminal.exited else { return }
        terminals[session]?.exited = true
        terminal.relay.stop()
        terminal.pty.terminate()
        shared.note(live: liveSessions)
        // Every viewer of this terminal, wherever it is. The census only answers an
        // attach that has not happened yet; a browser or an iPad already watching
        // this session has nothing else to learn from and would otherwise stay on a
        // socket that never speaks again.
        onStreamEnded(session)
        onTerminated(session)
    }

    /// On this substrate focusing a row means showing it in the pane. There is no
    /// window to raise: the terminal is already inside the app's only window.
    ///
    /// An exited terminal is answered exactly as an absent one, which is what lets
    /// a stopped row be revived. `ProjectStore.activate` reopens whatever `focus`
    /// reports not found, so answering `found: true` for a corpse left the play
    /// button on a finished Claude row doing nothing at all: the row could not
    /// reopen, and `jobKnown` was false because the master was closed, so the store
    /// had nothing to act on either. The other two substrates answer not-found here
    /// because their session really is gone; this one has to say so itself, because
    /// the entry survives on purpose.
    func focus(sessionId: String) async throws -> FocusResult {
        guard let terminal = terminals[sessionId], !terminal.exited else {
            // Not found, and nothing known about a job. `jobKnown: false` matters:
            // `ProjectStore.activate` types `claude` into a Claude row whose agent
            // it believes is idle, so an absence read as "no job" submits that
            // text into a live agent as a prompt.
            return FocusResult(found: false, jobName: nil, jobKnown: false)
        }
        select(sessionId)
        let job = terminal.pty.foregroundJobName()
        return FocusResult(found: true, jobName: job, jobKnown: job != nil)
    }

    /// Input goes to the pty master, not to the surface. Local keystrokes arrive
    /// the same way, through the relay, so both orders are the pty's and there is
    /// one path to get wrong instead of two.
    ///
    /// Main actor isolated and yet safe to call with a megabyte of pasted text,
    /// because `RawPTY.write` hands the bytes to that pty's own serial queue rather
    /// than performing the write here. A master write blocks once the child stops
    /// reading, so doing it here froze the UI until the foreground program read its
    /// stdin, which it need never do.
    ///
    /// An exited terminal throws rather than accepting the write. Its master is
    /// closed, so the bytes went nowhere and nothing said so: an MCP `send_input`
    /// and a remote keystroke both looked like they had been delivered.
    func send(sessionId: String, text: String) async throws {
        guard let terminal = terminals[sessionId] else {
            throw TerminalError.failed("No terminal named \(sessionId).")
        }
        guard !terminal.exited else {
            throw TerminalError.failed("Terminal \(sessionId) has exited.")
        }
        terminal.pty.write(Array(text.utf8))
    }

    func close(sessionId: String) async throws {
        tearDown(sessionId)
    }

    /// Stops the child but keeps the row: `reap` terminates the pty and marks the
    /// entry exited while leaving its surface and last screen in place, the same
    /// path a command that exits on its own takes, so the row dims and can be
    /// reopened rather than disappearing the way `close` makes it.
    func stop(sessionId: String) async {
        reap(sessionId)
    }

    /// Frees what a terminal whose id `focus` has just reported gone is still
    /// holding, so the replacement the caller is about to open does not leave the
    /// old surface behind.
    ///
    /// This is the other half of keeping a dead terminal's last screen readable.
    /// The entry, its surface and its `NSView` survive the child on purpose, and
    /// nothing but closing the row used to remove them, so once `focus` started
    /// answering not-found for an exited terminal the reopen would have leaked a
    /// surface and a view per revival for the life of the process. Called from the
    /// reopen path rather than from `focus`, because `focus` is also the MCP select
    /// and a query must not destroy the screen it was asked about: the moment of
    /// revival is the one moment the screen is genuinely finished with.
    ///
    /// A no-op for a live terminal, and that guard is load bearing rather than
    /// defensive: a caller that reached here with a running terminal would turn a
    /// click on a live row into a silent close.
    func discard(sessionId: String) async {
        guard terminals[sessionId]?.exited == true else { return }
        tearDown(sessionId)
    }

    /// Retires a terminal for good: the relay, the pty, the surface and the
    /// recorded screen all go, and its viewers are told.
    private func tearDown(_ sessionId: String) {
        guard let terminal = terminals.removeValue(forKey: sessionId) else { return }
        // Both are idempotent, which is what makes closing a row whose child was
        // already reaped safe: `stop` returns at once and `terminate` signals
        // nothing twice.
        terminal.relay.stop()
        terminal.pty.terminate()
        host.destroySurface(id: sessionId)
        shared.note(live: liveSessions)
        // Cleared, not left stale: an attach to this id must be answered `ended`
        // by the census, and a snapshot left behind would paint a dead screen for
        // an id the app may later mint again.
        shared.record(nil, for: sessionId)
        // Told even when the child was reaped earlier, because a viewer can attach
        // between the two: the census answers an attach on a reaped terminal
        // `ended`, but a viewer that attached while it was alive is still here.
        // Ending a second time reaches nobody, since the first ended them all.
        onStreamEnded(sessionId)
        if selected == sessionId { select(terminals.keys.first) }
    }

    func readOutput(sessionId: String, maxLines: Int) async throws -> String {
        guard terminals[sessionId] != nil else {
            throw TerminalError.failed("No terminal named \(sessionId).")
        }
        // The caller's `maxLines` is honoured here, unlike in `recordSnapshot`.
        // Reaching scrollback is the whole point of this method: it answers an MCP
        // read of what a terminal has printed, which is rarely only the last
        // screenful, and it runs once per request rather than once per notch of a
        // window drag.
        //
        // The live read first, because only it can reach scrollback, and it answers
        // in full for the one pane the window is showing. But libghostty's
        // `read_text` returns nothing for a surface that is not on screen, and an MCP
        // read is almost always of a session that is not the displayed pane. So an
        // empty live read falls back to the screen recorded from the terminal's own
        // output within `snapshotDebounce`, which is the viewport rather than the
        // scrollback but is what the terminal actually printed rather than "".
        if let live = host.snapshot(id: sessionId, maxLines: maxLines), !live.rows.isEmpty {
            return live.rows.joined(separator: "\n")
        }
        guard let recorded = shared.snapshot(for: sessionId) else { return "" }
        return recorded.rows.joined(separator: "\n")
    }

    func select(_ session: String?) {
        guard selected != session else { return }
        // The outgoing terminal's screen is recorded before it leaves the view
        // hierarchy. It keeps running and keeps producing bytes, but nothing
        // refreshes its snapshot again until it comes back, so this is the last
        // chance to capture what a viewer attaching to it would want to see.
        if let outgoing = selected, terminals[outgoing] != nil { recordSnapshot(outgoing) }
        selected = session
        if let session, terminals[session] != nil { recordSnapshot(session) }
        onSelectionChanged?(session)
    }

    /// One event per live terminal whose foreground job is known.
    ///
    /// A terminal whose `tcgetpgrp` failed contributes nothing rather than an
    /// event with an empty name. `ProjectStore.runState` treats a job it has never
    /// been told as unknown, which is the correct reading of a failed query, and
    /// the same rule `FocusResult.jobKnown` encodes.
    /// An exited terminal is skipped rather than queried. Its master is closed, so
    /// the query would fail and contribute nothing anyway, but skipping it says
    /// why.
    func jobEvents() -> [MonitorEvent] {
        terminals.compactMap { session, terminal in
            guard !terminal.exited else { return nil }
            return terminal.pty.foregroundJobName().map { .job(sessionId: session, jobName: $0) }
        }
    }

    /// Tears every terminal down. Called on app teardown and by tests, so a
    /// leaked pty does not outlive the process that owns its socket file.
    func closeAll() {
        for (session, terminal) in terminals {
            terminal.relay.stop()
            terminal.pty.terminate()
            host.destroySurface(id: session)
            shared.record(nil, for: session)
            // Told here too, and it is not only for tidiness at exit: this is also
            // the teardown a test performs while a viewer is attached.
            onStreamEnded(session)
        }
        terminals = [:]
        shared.note(live: [])
        select(nil)
    }
}
