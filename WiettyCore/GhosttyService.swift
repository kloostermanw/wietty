import Foundation
import OSLog

/// The parts of the terminal registry `PaneStreamHub` reads, behind a lock rather
/// than the main actor.
///
/// The hub asks from its own queues and cannot wait for a hop to the main actor.
/// The census gates an attach, which has to be answered before the viewer is
/// registered. A terminal's screen model is fed on the pty's read thread with every
/// chunk and asked for a frame on the hub's delivery queue, under the hub's lock
/// for that session. A remote viewer's input is handed to the terminal's writer on
/// whatever thread it arrived on. Hopping any of them would put a terminal's bytes,
/// a viewer's first frame, or a keystroke behind whatever the UI is doing.
package final class SharedTerminalState: @unchecked Sendable {
    private let lock = NSLock()
    private var live: Set<String> = []
    private var models: [String: any TerminalScreenModel] = [:]
    private var writers: [String: @Sendable ([UInt8]) -> Void] = [:]
    private var resizers: [String: @Sendable (TerminalSize) -> Void] = [:]
    private var readStarts: [String: @Sendable () -> Void] = [:]

    /// `GhosttyService` builds the app's one instance. Reachable from the tests so
    /// `StreamBaselineTests` can wire the hub to a model exactly as `GhosttyStack` does.
    package init() {}

    package var liveSessions: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    package func note(live sessions: Set<String>) {
        lock.lock(); live = sessions; lock.unlock()
    }

    /// The screen model of a terminal, or nil for one that was never opened or has
    /// been torn down. An exited terminal keeps its model until its row is closed,
    /// as it keeps its surface: the last screen a command left is still worth
    /// reading.
    ///
    /// Here, behind this lock, because the hub looks it up off the main actor,
    /// to feed it and to paint from it. The lock covers only the lookup. The model serialises its
    /// own calls, so a caller uses what it is handed without holding anything of
    /// this type's.
    package func model(for session: String) -> (any TerminalScreenModel)? {
        lock.lock(); defer { lock.unlock() }
        return models[session]
    }

    package func note(model: any TerminalScreenModel, for session: String) {
        lock.lock(); models[session] = model; lock.unlock()
    }

    /// Releases a terminal's model. This is the registry's only reference once the
    /// relay that fed it has stopped, so the terminal's memory goes with it.
    package func removeModel(for session: String) {
        lock.lock(); models[session] = nil; lock.unlock()
    }

    /// What writes a terminal's input to its pty, for the hub to hand a remote
    /// viewer's bytes to without the main actor. The writer queues them on the
    /// pty's own serial queue, so calling it from any thread is safe and keeps
    /// the order of the calls.
    package func register(writer: @escaping @Sendable ([UInt8]) -> Void, for session: String) {
        lock.lock(); writers[session] = writer; lock.unlock()
    }

    /// The writer of a terminal that is open and has not exited, or nil.
    package func writer(for session: String) -> (@Sendable ([UInt8]) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return writers[session]
    }

    package func removeWriter(for session: String) {
        lock.lock(); writers[session] = nil; lock.unlock()
    }

    /// What resizes a terminal's pty and then its model, for the hub to call when a
    /// viewer claims a grid, without the main actor. Both serialise their own calls,
    /// so calling it from any thread is safe.
    package func register(resizer: @escaping @Sendable (TerminalSize) -> Void, for session: String) {
        lock.lock(); resizers[session] = resizer; lock.unlock()
    }

    /// The resizer of a terminal that is open and has not exited, or nil.
    package func resizer(for session: String) -> (@Sendable (TerminalSize) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return resizers[session]
    }

    package func removeResizer(for session: String) {
        lock.lock(); resizers[session] = nil; lock.unlock()
    }

    /// What starts reading a terminal's pty, kept until the first of its two
    /// triggers takes it: the pane's own viewer attaching (`PaneStreamHub`'s
    /// `onLocalViewerAttached`, on the hub's delivery queue) or the wait for it
    /// running out (on a timer's thread). Behind this lock, so the two cannot both
    /// have it, and so neither waits for the main actor.
    package func register(readStart: @escaping @Sendable () -> Void, for session: String) {
        lock.lock(); readStarts[session] = readStart; lock.unlock()
    }

    /// Removes and returns a terminal's read start: whoever gets it is the one
    /// caller that may run it. Nil once taken, and for a terminal closed before
    /// either trigger, which therefore never reads.
    package func takeReadStart(for session: String) -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return readStarts.removeValue(forKey: session)
    }
}

/// The libghostty substrate's `TerminalService`.
///
/// A terminal here is three things that live and die together: a `RawPTY` running
/// the user's shell, a `TerminalRelay` reading it into `PaneStreamHub`, and a
/// libghostty surface rendering it. This type is what keeps the three in step, and
/// it is the only place that knows a terminal is not a single object.
///
/// The surface is a viewer of the stream like any other: the host gives it a bridge
/// that attaches to the hub through `LocalStreamServer` as the session's local
/// viewer. So this asks the host only for a surface for a session, and builds no
/// command.
///
/// A session id is minted here (`gt:<uuid>`) rather than taken from a substrate,
/// because there is no substrate to ask: the PTY belongs to the app.
///
/// Main actor isolated, because the surface host is. The byte path is not: it
/// runs on the pty's read thread and touches only `PaneStreamHub`, which is
/// lock protected. That split is deliberate. Hopping every chunk of terminal
/// output to the main actor would put a shell's output behind the UI's work.
@MainActor
package final class GhosttyService: TerminalService {
    private static let log = Logger(subsystem: "eu.kloosterman.wietty", category: "terminal-service")

    /// How long a new terminal waits for the pane's own viewer before its pty is
    /// read anyway. See `open`.
    package nonisolated static let unattachedReadDelay: TimeInterval = 5

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
    private let shell: String
    /// How long `open` lets a terminal wait for its pane's viewer before reading
    /// its pty anyway (`unattachedReadDelay` unless a test says otherwise).
    private let readDelay: TimeInterval
    /// Where the error for a terminal read without its pane goes. The log, unless a
    /// test listens.
    private let reportUnattachedRead: @Sendable (String) -> Void
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
    /// A program status report (`OSC 7501`), a new shell prompt or a full reset,
    /// read off a terminal's output. Called on that terminal's read queue, in stream
    /// order, so whoever forwards it has to keep that order. The support query is
    /// answered on the pty here and never reaches this.
    ///
    /// Defaulted to nothing, like `onResized`: answering the query is part of
    /// running a terminal, hearing the reports is not.
    private let onProgramStatus: @Sendable (String, ProgramStatusScanner.Event) -> Void
    private let onTerminated: @MainActor (String) -> Void
    /// Builds the screen model of a terminal that is being opened, at the grid it
    /// is opened with, keeping at most the history `scrollbackLines` answers with,
    /// and with grapheme clustering as the host says its surfaces have it. Injected
    /// so a test can hand the service a model it can inspect; the default is the
    /// real one.
    private let makeScreenModel: @MainActor (TerminalSize, _ scrollbackLines: Int,
                                             _ graphemeClustering: Bool) throws
        -> any TerminalScreenModel

    /// How many lines of history the next terminal's model is built to keep.
    ///
    /// Asked in `open`, on the main actor, once per terminal, and never from the
    /// pty's read thread or the hub's queue: a model is handed its limit when it is built and
    /// nothing reads the setting after that. So a change reaches terminals opened
    /// after it, and one that is already open keeps what it started with.
    ///
    /// A closure the owner of the setting points at itself, rather than a value
    /// passed in, because the service is built before the store that holds the
    /// setting (`GhosttyStack.followScrollbackSetting(of:)`). The default until
    /// then, and for a service nothing is wired to.
    package var scrollbackLines: @MainActor () -> Int = { TerminalScrollback.defaultLines }
    private var terminals: [String: Terminal] = [:]

    /// The terminal the frontend says is on screen, as it last told us.
    ///
    /// Remembered rather than decided. The service used to own the selection and move
    /// it, which meant an MCP tool call or a tap on an iPad moved the Mac's pane as a
    /// side effect of asking a question. The frontend decides and calls
    /// `displayedSessionChanged`. The one thing left that reads this is `tearDown`,
    /// which asks for another terminal to be shown when the one that went was the
    /// one on screen. Nothing that can be read depends on it any more: a
    /// terminal's screen is held by its model, displayed or not.
    private var displayedSession: String?

    /// The service would like a terminal shown, or the pane emptied.
    ///
    /// A request, not an instruction: a frontend may honour it, and with no frontend
    /// attached there is nobody to, which is the whole point of phase 5. Raised when a
    /// terminal is opened, when the displayed one is closed and another remains, and
    /// when everything is torn down.
    private let onDisplayRequest: @MainActor (String?) -> Void

    /// The registry as `PaneStreamHub` sees it, off the main actor.
    ///
    /// `nonisolated` rather than plain `let`, and it has to be: the hub reads this
    /// from its own delivery queue, so an access that needed a hop to the main
    /// actor would not compile there at all.
    package nonisolated let shared = SharedTerminalState()

    /// What every session id this app mints starts with.
    ///
    /// One definition, because two things read it: `open`, which mints them, and
    /// `ProjectStore.clearDeadSessions`, which is how the launch wipe tells an id
    /// this build could have minted from a leftover written by an older one.
    ///
    /// `nonisolated` because the store answers that question from its own
    /// `@MainActor` context and a test may ask from anywhere; an immutable string
    /// needs no isolation to be read.
    package nonisolated static let sessionPrefix = "gt:"

    /// The size a terminal starts at, before any surface has been laid out. A
    /// terminal has to be spawned with some grid, and a full screen program lays
    /// itself out from what it finds; the first `onResized` corrects it.
    package static let initialSize = TerminalSize(cols: 120, rows: 34)

    /// The terminals whose child is still running. A reaped one is deliberately
    /// absent: this is the census a remote viewer's attach is gated on, and an
    /// exited terminal must be answered `ended` rather than streamed.
    package var liveSessions: Set<String> {
        Set(terminals.lazy.filter { !$0.value.exited }.map(\.key))
    }

    /// - Parameter readDelay: how long a terminal waits for its pane's own viewer
    ///   before its pty is read anyway; see `open`.
    /// - Parameter reportUnattachedRead: told, with the message, when that wait runs
    ///   out. Logs it as an error by default.
    package init(host: any TerminalSurfaceHosting,
         shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
         readDelay: TimeInterval = GhosttyService.unattachedReadDelay,
         reportUnattachedRead: @escaping @Sendable (String) -> Void = { message in
             GhosttyLog.stack.error("\(message, privacy: .public)")
         },
         onOutput: @escaping @Sendable (String, [UInt8]) -> Void,
         onResized: @escaping @Sendable (String, TerminalSize) -> Void = { _, _ in },
         onStreamEnded: @escaping @Sendable (String) -> Void = { _ in },
         onProgramStatus: @escaping @Sendable (String, ProgramStatusScanner.Event) -> Void = { _, _ in },
         onDisplayRequest: @escaping @MainActor (String?) -> Void = { _ in },
         makeScreenModel: @escaping @MainActor (TerminalSize, _ scrollbackLines: Int,
                                                _ graphemeClustering: Bool) throws
             -> any TerminalScreenModel
             = { try GhosttyVtScreenModel(size: $0, scrollbackLines: $1, graphemeClustering: $2) },
         onTerminated: @escaping @MainActor (String) -> Void) {
        self.host = host
        self.shell = shell
        self.readDelay = readDelay
        self.reportUnattachedRead = reportUnattachedRead
        self.onOutput = onOutput
        self.onResized = onResized
        self.onStreamEnded = onStreamEnded
        self.onProgramStatus = onProgramStatus
        self.onDisplayRequest = onDisplayRequest
        self.makeScreenModel = makeScreenModel
        self.onTerminated = onTerminated
        host.onResized = { [weak self] session, size in
            guard let self else { return }
            // Only for a terminal this service holds. A report for anything else
            // names no pty to resize and no screen worth telling a viewer about.
            guard let terminal = self.terminals[session] else { return }
            terminal.pty.resize(to: size)
            // The model follows the same report, so its grid is the surface's. The
            // surface stays the authority: the model is told, never asked.
            //
            // BEFORE the report below, because that report is what makes an already
            // attached viewer repaint, and the repaint is taken from the model: told
            // first, it would paint the screen as it was before the reflow and then
            // be contradicted by the bytes the reflow produced.
            self.shared.model(for: session)?.resize(to: size)
            self.onResized(session, size)
        }
        // libghostty asking for a surface to be closed means the terminal has
        // ended, so it is retired exactly as an exit noticed on the pty is. After
        // the user's `exit` the pty's EOF arrives first and reaps; the stream then
        // ends the pane's link, its bridge is stopped, the helper exits, and
        // libghostty's close request for that reaches here and finds the terminal
        // already exited, so `reap`'s guard makes it nothing. A request that comes
        // first (a `close_surface` keybinding in the user's own Ghostty
        // configuration, which has no other way in, or a helper that died) does
        // the work instead.
        host.onCloseRequested = { [weak self] session in self?.reap(session) }
    }

    /// Opens a terminal: a model, a pty running the shell, a relay to read it, and a
    /// surface whose bridge attaches to the stream as the session's local viewer.
    ///
    /// **The pty is read only once the pane's viewer has attached** (decision P2).
    /// Its first snapshot is then the empty screen, and every byte the child writes
    /// reaches the pane through the stream, none of it folded into a snapshot taken
    /// before the pane could read. Reading starts when the hub reports the session's
    /// first local viewer (`localViewerAttached(session:)`), or after `readDelay` if
    /// none has, whichever is first, and exactly once: whichever takes the read start
    /// from `shared` runs it. The second path is reported as an error, since a pane
    /// that does not attach is a fault, but a terminal that never reads would hang its
    /// child at the first full buffer. A terminal closed or failed before either takes
    /// the read start away, and never reads.
    ///
    /// **The session is live before its surface is asked for.** The bridge's link
    /// attaches from its own thread as soon as the helper connects, which can be
    /// before `createSurface` returns, and an attach for a session the census does not
    /// hold is answered `ended`. A failed `createSurface` takes it out again.
    package func open(folder: URL, existingWindowId: String?, command: String?,
              badge: String?) async throws -> TerminalHandle {
        let session = Self.sessionPrefix + UUID().uuidString.lowercased()
        // Before the pty, so a model that cannot be built leaves nothing to clean
        // up. At the grid the pty is about to be spawned with, which is the only
        // grid there is until the surface reports its own.
        //
        // Grapheme clustering is asked of the host here, once, because this is the
        // moment the surface is created from the same configuration. A terminal
        // that is already open keeps what it started with, as its surface's
        // default modes do. The scrollback limit is read here for the same reason
        // and with the same consequence. Clamped here as well as where the setting
        // is stored, so no caller can build a model outside the documented range.
        let model = try makeScreenModel(Self.initialSize,
                                        TerminalScrollback.clamped(scrollbackLines()),
                                        host.graphemeClustering)
        let pty = try RawPTY.spawn(command: command, directory: folder, environment: [:],
                                   size: Self.initialSize, shell: shell)
        let onOutput = self.onOutput
        let onProgramStatus = self.onProgramStatus
        // Weakly, like every other write a terminal outlives: a pty that has been
        // released has nobody left to answer.
        let status = ProgramStatusTap(reply: { [weak pty] answer in pty?.write(answer) },
                                      report: { event in onProgramStatus(session, event) })
        let relay = TerminalRelay(pty: pty) { bytes in
            // Ahead of everything, because this is what answers `OSC 7501 ; ?`,
            // and that answer has to be queued before the hub hands this chunk to
            // the pane and libghostty answers what follows the query.
            // `ProgramStatusTap` says why.
            status.ingest(bytes)
            // The hub next and unconditionally: it is every viewer's path, the
            // pane's own included, and this runs on the pty's thread precisely so
            // no byte waits behind anything else.
            //
            // This is also what feeds the terminal's screen model. Not a line
            // of its own here, on purpose: the hub writes the model in the
            // same step that accepts the chunk for delivery, which is the
            // only way a paint taken from the model can line up with the
            // stream that follows it. See `PaneStreamHub.onIngest`.
            onOutput(session, bytes)
        }

        // Registered before the surface is asked for: the pane's viewer can attach
        // while `createSurface` runs, and its snapshot is taken from this model.
        shared.note(model: model, for: session)
        // Weakly, like the status tap's reply: the registry must not keep a pty
        // alive, and one that has been released has nobody left to read input.
        shared.register(writer: { [weak pty] bytes in pty?.write(bytes) }, for: session)
        // What a viewer's claim of a grid resizes, off the main actor: the pty, and
        // then the model, in the order `host.onResized` keeps. Weakly, for the same
        // reason as the writer.
        shared.register(resizer: { [weak pty, weak model] size in
            pty?.resize(to: size)
            model?.resize(to: size)
        }, for: session)
        // The child's exit is noticed by the read, so a terminal that never reads
        // is reaped by its close instead.
        let onExit: @Sendable (Int32) -> Void = { [weak self] _ in
            Task { @MainActor in self?.reap(session) }
        }
        shared.register(readStart: { relay.start(onExit: onExit) }, for: session)
        terminals[session] = Terminal(pty: pty, relay: relay)
        // Live before the surface exists; see the doc above.
        shared.note(live: liveSessions)

        // `badge` travels as the surface's title. libghostty has no title setter,
        // so today it reaches the host's own record and the view's accessibility
        // label and no further: it labels nothing a sighted user can see. It is
        // still passed rather than dropped, because the alternative is a substrate
        // that silently ignores a workspace setting the other two honour, and the
        // day the C API grows a setter this already carries the value.
        do {
            try host.createSurface(id: session, directory: folder, title: badge)
        } catch {
            // Nothing will read this terminal: everything registered above goes,
            // and a viewer that attached meanwhile is told it ended.
            terminals[session] = nil
            _ = shared.takeReadStart(for: session)
            relay.stop()
            pty.terminate()
            shared.note(live: liveSessions)
            shared.removeModel(for: session)
            shared.removeWriter(for: session)
            shared.removeResizer(for: session)
            onStreamEnded(session)
            throw error
        }

        // The pane's viewer had its chance. Not on the main actor: neither the
        // start nor the report needs it, and the wait must not depend on it.
        let shared = self.shared
        let report = reportUnattachedRead
        let delay = readDelay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            guard let start = shared.takeReadStart(for: session) else { return }
            report("""
                terminal \(session) is read without its pane: no local viewer attached \
                within \(delay) seconds
                """)
            start()
        }
        onDisplayRequest(session)

        // `windowId` is echoed back rather than minted. Nothing here is a window,
        // and `ProjectStore.recordWorkspaceId` writes whatever comes back onto
        // `Project.windowId`, so minting a value would invent a name nothing reads.
        return TerminalHandle(sessionId: session, windowId: existingWindowId ?? "")
    }

    /// The pane's own viewer of `session` has attached: its pty is read from now on,
    /// unless that has started already or the terminal is gone.
    ///
    /// Called by `PaneStreamHub.onLocalViewerAttached`, on the hub's delivery queue,
    /// with no lock of the hub's held. It calls nothing of the hub's: starting the
    /// read only installs the pty's read source, whose first chunk reaches the hub
    /// later on the pty's own thread.
    package nonisolated func localViewerAttached(session: String) {
        shared.takeReadStart(for: session)?()
    }

    /// Retires a terminal whose child has exited: the relay and the pty go, the
    /// census stops counting it, and only then is the caller told.
    ///
    /// The service reaps itself rather than leaving it to whoever wired the
    /// callback. `terminals` is the source of truth, so a corpse left in it is a
    /// broken invariant inside the one type that owns
    /// it: the census reports a dead terminal as attachable, and `jobEvents` polls a
    /// closed master until someone remembers to call `close`. Requiring every future construction of this
    /// service to remember that wiring is exactly the seam that gets forgotten.
    ///
    /// The order matters. The viewers are told, and then `onTerminated` last, so a
    /// handler that asks `liveSessions` what is running never sees the terminal it
    /// is being told about.
    ///
    /// The surface is deliberately NOT destroyed, and neither is the model. The
    /// last screen the command left behind is what an MCP read wants when
    /// something died, and `readOutput` keeps answering from the model; `close`,
    /// `discard` and `closeAll` are what tear both down. Guarded by `exited`,
    /// because the child can be reaped once and closed later and neither may free
    /// anything twice.
    private func reap(_ session: String) {
        guard let terminal = terminals[session], !terminal.exited else { return }
        terminals[session]?.exited = true
        // A terminal that ends before its pty was ever read (a close request, a
        // stop) is not read afterwards either.
        _ = shared.takeReadStart(for: session)
        terminal.relay.stop()
        terminal.pty.terminate()
        shared.note(live: liveSessions)
        // The writer goes now and the model stays: the master is closed, so input
        // for this terminal is refused here as `send` refuses it, rather than
        // handed to a pty that drops it without a word.
        shared.removeWriter(for: session)
        shared.removeResizer(for: session)
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
    package func probe(sessionId: String) async throws -> FocusResult {
        guard let terminal = terminals[sessionId], !terminal.exited else {
            // Not found, and nothing known about a job. `jobKnown: false` matters:
            // `ProjectStore.activate` types `claude` into a Claude row whose agent
            // it believes is idle, so an absence read as "no job" submits that
            // text into a live agent as a prompt.
            return FocusResult(found: false, jobName: nil, jobKnown: false)
        }
        let job = terminal.pty.foregroundJobName()
        return FocusResult(found: true, jobName: job, jobKnown: job != nil)
    }

    /// Input goes to the pty master, not to the surface. Local keystrokes arrive
    /// the same way, through the pane's bridge and the hub's writer, so both orders
    /// are the pty's and there is one path to get wrong instead of two.
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
    package func send(sessionId: String, text: String) async throws {
        guard let terminal = terminals[sessionId] else {
            throw TerminalError.failed("No terminal named \(sessionId).")
        }
        guard !terminal.exited else {
            throw TerminalError.failed("Terminal \(sessionId) has exited.")
        }
        terminal.pty.write(Array(text.utf8))
    }

    package func close(sessionId: String) async throws {
        tearDown(sessionId)
    }

    /// Stops the child but keeps the row: `reap` terminates the pty and marks the
    /// entry exited while leaving its surface and last screen in place, the same
    /// path a command that exits on its own takes, so the row dims and can be
    /// reopened rather than disappearing the way `close` makes it.
    ///
    /// Stopping an already-exited entry is a legitimate no-op (`reap` guards it), but
    /// stopping one the service has never heard of means a store row is pointing at a
    /// session this side has already torn down: a desync worth a log rather than a
    /// silent return, since every throwing API treats an unknown id as an error.
    package func stop(sessionId: String) async {
        if terminals[sessionId] == nil {
            Self.log.error("stop: no terminal named \(sessionId, privacy: .public)")
            return
        }
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
    package func discard(sessionId: String) async {
        guard terminals[sessionId]?.exited == true else { return }
        tearDown(sessionId)
    }

    /// Retires a terminal for good: the relay, the pty, the surface (and with it
    /// the pane's bridge and its socket) and the screen model all go, and its
    /// viewers are told.
    private func tearDown(_ sessionId: String) {
        guard let terminal = terminals.removeValue(forKey: sessionId) else { return }
        // Closed before its pane attached or the wait ran out: never read.
        _ = shared.takeReadStart(for: sessionId)
        // Both are idempotent, which is what makes closing a row whose child was
        // already reaped safe: `stop` returns at once and `terminate` signals
        // nothing twice.
        terminal.relay.stop()
        terminal.pty.terminate()
        host.destroySurface(id: sessionId)
        shared.note(live: liveSessions)
        // The model goes with the surface. `reap` deliberately keeps both. Gone,
        // not left behind: a full scrollback is megabytes, and an attach to this
        // id is answered `ended` by the census from here on.
        shared.removeModel(for: sessionId)
        shared.removeWriter(for: sessionId)
        shared.removeResizer(for: sessionId)
        // Told even when the child was reaped earlier, because a viewer can attach
        // between the two: the census answers an attach on a reaped terminal
        // `ended`, but a viewer that attached while it was alive is still here.
        // Ending a second time reaches nobody, since the first ended them all.
        onStreamEnded(sessionId)
        // Only when the one that went was the one on screen, which is the rule the
        // selection had when it lived here.
        if displayedSession == sessionId { onDisplayRequest(terminals.keys.first) }
    }

    /// A terminal's screen model, from wherever it is asked for.
    ///
    /// `nonisolated`, because the readers this exists for are not all on the main
    /// actor: the hub paints from its own delivery queue. Nil for a session this
    /// service does not hold.
    package nonisolated func screenModel(for sessionId: String) -> (any TerminalScreenModel)? {
        shared.model(for: sessionId)
    }

    /// What a terminal has printed, as plain text: the last `maxLines` lines, most
    /// recent last, a wrapped line joined into one and the blank rows below the
    /// last line left off.
    ///
    /// Answered by the terminal's own screen model, so it does not matter whether
    /// the terminal is the one on screen, or whether a window exists at all. It
    /// used to be read off the surface, which only answers while it is displayed,
    /// so a read of any other terminal, which is nearly every read an agent
    /// makes, fell back to one recorded viewport however many lines were asked
    /// for. The model holds the scrollback and reaches as far into it as the
    /// caller asks.
    ///
    /// An exited terminal still answers, because it keeps its model until its row
    /// is closed or reopened: the last screen a command left is exactly what is
    /// wanted when something died.
    package func readOutput(sessionId: String, maxLines: Int) async throws -> String {
        guard terminals[sessionId] != nil else {
            throw TerminalError.failed("No terminal named \(sessionId).")
        }
        return shared.model(for: sessionId)?.text(maxLines: maxLines) ?? ""
    }

    /// The frontend has put a different terminal on screen.
    ///
    /// All that is left of what `select` did is remembering it, for `tearDown`.
    /// This used to record the outgoing and the incoming terminal's screen,
    /// because a surface can only be read while it is displayed. A terminal's
    /// screen is held by its model now, so what can be read no longer depends on
    /// what is on screen and there is nothing to capture on the way past.
    package func displayedSessionChanged(from previous: String?, to current: String?) {
        displayedSession = current
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
    package func jobEvents() -> [MonitorEvent] {
        terminals.compactMap { session, terminal in
            guard !terminal.exited else { return nil }
            return terminal.pty.foregroundJobName().map { .job(sessionId: session, jobName: $0) }
        }
    }

    /// Tears every terminal down, its surface and the pane's bridge with it. Called on
    /// app teardown and by tests, so a leaked pty does not outlive the app and no
    /// bridge leaves its socket file behind.
    package func closeAll() {
        for (session, terminal) in terminals {
            _ = shared.takeReadStart(for: session)
            terminal.relay.stop()
            terminal.pty.terminate()
            host.destroySurface(id: session)
            shared.removeModel(for: session)
            shared.removeWriter(for: session)
            shared.removeResizer(for: session)
            // Told here too, and it is not only for tidiness at exit: this is also
            // the teardown a test performs while a viewer is attached.
            onStreamEnded(session)
        }
        terminals = [:]
        shared.note(live: [])
        onDisplayRequest(nil)
    }
}
