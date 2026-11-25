import Foundation

/// Composition root for the terminal stack. Builds the pieces, wires the byte and
/// event routing between them, and reports a stack that cannot work through
/// `setupError`.
///
/// It always constructs. A libghostty that will not initialise, a missing bundled
/// helper or a local socket that cannot be bound is reported rather than thrown, so
/// the app launches and can explain itself instead of failing at every call site.
///
/// The host is injected so tests can drive the whole stack with no framework and
/// no Metal device. `WiettyApp` passes the real `GhosttySurfaceHost`.
@MainActor
package final class GhosttyStack {
    /// The one streaming path, shared with the app's own pane, whose viewer reaches it
    /// through `localServer`. That sharing is why stopping the LAN server must not
    /// stop the hub: `stop()` cancels the flush timer permanently, so tearing the
    /// server down would leave every later local viewer silent.
    package let hub: PaneStreamHub
    package let service: any TerminalService
    package let monitor: any SessionMonitoring
    package private(set) var setupError: String?

    /// Where `localServer` listens: the socket every pane's bridge connects to.
    package let localSocketPath: String
    /// Serves the hub to the app's own panes, as local viewers. Built and started
    /// here, whether or not remote access is on: the panes depend on it and
    /// `RemoteServer` exists only while that setting is. Nil on a stack that could
    /// not be built. Stopped by `shutDown()`.
    package let localServer: LocalStreamServer?

    /// The concrete service, for the pane, which needs the selection and the
    /// views, and for teardown. Nil when the stack could not be built.
    package private(set) var ghosttyService: GhosttyService?
    private let ghosttyMonitor: GhosttyMonitor?
    /// Held so the pane can ask for a session's view. The pane must not reach the
    /// host directly: it is the seam onto an unstable API and only this stack owns
    /// it.
    private let host: any TerminalSurfaceHosting

    /// - Parameter localSocketPath: where `localServer` binds. The app passes
    ///   `LocalSocketPaths.server()`; a path that cannot be bound is a startup error.
    /// - Parameter startupFailure: why the app could not give this stack what it
    ///   needs, or nil when it could: libghostty would not initialise, or the bundled
    ///   helper the surfaces run is missing, or the socket path could not be made.
    ///   Passed in rather than patched on afterwards so that ONE error both reaches
    ///   `setupError` and is thrown by every terminal action. Reporting one reason
    ///   and throwing a different one sends the user to fix the wrong thing.
    /// - Parameter readDelay: how long a new terminal waits for its pane's viewer
    ///   before its pty is read anyway (see `GhosttyService.open`). Shorter in tests,
    ///   whose hosts have no pane to attach.
    package init(host: any TerminalSurfaceHosting, localSocketPath: String,
                 startupFailure: TerminalError? = nil,
                 readDelay: TimeInterval = GhosttyService.unattachedReadDelay) {
        // Built first and captured by value below: the service is handed its hook
        // while this initializer runs, before `self` can be read.
        let requests = DisplayRequests()
        self.displayRequests = requests
        let hub = PaneStreamHub(startTimer: true)
        self.hub = hub
        self.host = host
        self.localSocketPath = localSocketPath
        // Every way this stack can be born broken reduces to one question, so there
        // is one guard below and no force unwrap: did the app hand over what a
        // terminal needs, and is the pane's socket bound?
        var failure = startupFailure
        var server: LocalStreamServer?
        if failure == nil {
            do {
                server = try LocalStreamServer(path: localSocketPath, streamer: hub)
            } catch {
                failure = .localSocketFailed(String(describing: error))
            }
        }
        guard failure == nil, let server else {
            let failure = failure ?? .localSocketFailed("no server")
            setupError = failure.errorDescription
            service = UnavailableTerminalService(error: failure)
            monitor = InactiveMonitor()
            ghosttyService = nil
            ghosttyMonitor = nil
            localServer = nil
            // A census even here, because this stack knows the answer with
            // certainty: it holds no terminals and
            // never will. `PaneStreamHub.attach` skips the `ended` short circuit
            // when the census is nil, and nothing upstream validates a session id,
            // so without this an attach upgrades a socket that then stays silent
            // forever. Leaving the hook nil would mean `.unknown`, which must not
            // end a viewer watching a terminal that is fine. An empty answer here is
            // not a failed query, it is the truth.
            hub.onSessionCensus = { .sessions([]) }
            return
        }
        localServer = server

        let monitor = GhosttyMonitor(host: host)
        let service = GhosttyService(
            host: host,
            readDelay: readDelay,
            // Straight into the hub, off the main actor, in stream order. This is
            // the whole reason Wietty owns the PTY: the same bytes reach the
            // app's own surface (a local viewer, through `localServer`), every
            // remote viewer, and the terminal's screen model, which the hub feeds
            // through `onIngest` below.
            onOutput: { session, bytes in hub.write(session: session, bytes: bytes) },
            // A terminal that has stopped for good, to the same hub, so an already
            // attached viewer is told rather than left on a socket that never
            // speaks again. The census only answers an attach that has not happened
            // yet, so without this a browser or an iPad watching a terminal whose
            // command exited went silent with no way to tell that from an idle
            // terminal. The service is the only thing that knows, because the
            // terminal is a PTY in this process.
            //
            // Both the exit and the close reach this, and they have to: a row closed
            // while a viewer watches it produces no `%window-close` equivalent
            // either.
            onStreamEnded: { session in hub.endViewers(ofSession: session) },
            // Program status read off the stream, to the monitor like a
            // termination, so the app still has one listener. This runs on the
            // terminal's read queue and the listener on the main actor. The hop is
            // one main queue block per event because that queue is FIFO: a `Task`
            // per event could run them out of order, and a `done` overtaken by the
            // `working` before it would leave the row saying working.
            onProgramStatus: { session, event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { monitor.emit([.programStatus(sessionId: session, event)]) }
                }
            },
            // A child exiting is the only source of `.terminated` here, and the
            // monitor is the app's single listener, so the service reports through
            // it rather than to the store directly.
            //
            // The service has already reaped the terminal before calling this, so
            // by the time the event is emitted the census no longer reports it as
            // live. That ordering is the service's own invariant and this hook
            // deliberately does not participate in it: a composition root that had
            // to remember to reap would be a seam that breaks the first time
            // someone builds a service another way.
            onDisplayRequest: { session in requests.call(session) },
            onTerminated: { session in monitor.emit([.terminated(sessionId: session)]) })

        // Every hook below reads `shared`, never the service itself. The hub calls
        // them from the pty's read thread and from its own delivery queue, and
        // `GhosttyService` is main actor isolated, so reaching into it here would
        // either deadlock or need an `assumeIsolated` that is simply untrue.
        // `SharedTerminalState` exists for exactly these questions.
        let shared = service.shared
        // Asked on attach, so a session id whose terminal is gone is answered with
        // `ended` rather than a socket that opens and then never speaks. It cannot
        // fail: the registry is in this process, so there is never an `.unknown` to
        // report.
        hub.onSessionCensus = { .sessions(shared.liveSessions) }
        // The server's own terminal, fed by the hub in the step that accepts a
        // chunk for delivery. The hub holds the session's lock across both, so a
        // frame asked for under that lock is the terminal at exactly the offset
        // the viewers are served from. A session with no model is one that has
        // been torn down while its relay was still draining, and those bytes have
        // nobody left to read them.
        hub.onIngest = { session, bytes in shared.model(for: session)?.write(bytes) }
        // What a viewer is sent on attach and on a resync: the model's history
        // and screen, with colours, modes and the real cursor, and the grid and
        // screen they were taken on. The two below are asked for by the hub under
        // the same session lock the line above is called under, which is what
        // makes them exact: each holds every byte the hub has accepted and none
        // it has not.
        hub.onSnapshot = { session in Self.snapshot(of: session, in: shared) }
        // The visible screen again, after the grid moved, for a viewer that asked
        // for repaints. A session with no model gives none, which the hub treats
        // as a frame that could not be built rather than as an empty screen.
        hub.onRepaint = { session in shared.model(for: session)?.repaintFrame() }
        // Asked after a write while a viewer that joined on the alternate screen
        // waits for the terminal to leave it.
        hub.onAlternateScreen = { session in shared.model(for: session)?.isAlternateScreen ?? false }
        // A remote viewer's input, straight to the terminal's pty, on the thread
        // the hub was handed it on. The pty queues it on its own serial queue, so
        // it arrives in the order it was sent and never waits for the main actor.
        hub.onInput = { session, bytes in Self.input(bytes, for: session, in: shared) }
        // A viewer's claim of a grid, to the pty and then the model of the terminal,
        // on the hub's delivery queue and before the hub takes its repaint. The one
        // path that resizes a terminal: the own pane claims through its bridge and
        // `LocalStreamServer`, a browser or an iPad through the attach route.
        hub.onClaim = { session, size in shared.resizer(for: session)?(size) }
        // A terminal's pty is read once its pane's viewer has attached, so the
        // pane's first snapshot is the empty screen and the pane is handed every
        // byte. Called on the hub's delivery queue; starting the read calls nothing
        // of the hub's. The one hook that names the service, through a
        // `nonisolated` method that reads only `shared`. Weakly, as the service
        // holds hooks that hold the hub.
        hub.onLocalViewerAttached = { [weak service] session in
            service?.localViewerAttached(session: session)
        }
        // The hub holds the escape state needed to tell a real bell from an OSC
        // terminator, but libghostty has already parsed both, so the surface's
        // bell is the one that is reported and this hook stays unwired.

        // Tearing every terminal down at quit belongs to `TerminalQuitTeardown`,
        // which `ServerRuntime` owns, and which calls `shutDown()`. It needs
        // `NSApplication` and this stack is on its way to a target with no AppKit
        // in it.
        server.start()

        self.service = service
        self.monitor = monitor
        self.ghosttyService = service
        self.ghosttyMonitor = monitor
    }

    /// The snapshot `onSnapshot` answers with, from the model `shared` holds for
    /// the session. Nil without a model, and for a frame with no bytes, which is
    /// one that could not be built: sent behind a full reset it would leave the
    /// viewer with nothing at all.
    ///
    /// Static, so `StreamBaselineTests` wires the hub with the very same code.
    package nonisolated static func snapshot(of session: String,
                                             in shared: SharedTerminalState) -> TerminalSnapshotFrame? {
        guard let frame = shared.model(for: session)?.snapshotFrame(), !frame.bytes.isEmpty else {
            return nil
        }
        return frame
    }

    /// What `onInput` does: hands the bytes to the writer the service registered
    /// for the session.
    ///
    /// A session with no writer is closed or has exited, and the bytes are
    /// dropped. Recorded rather than discarded, because a row that had stopped
    /// accepting input was otherwise indistinguishable from one being typed into
    /// correctly; not an alert, because a terminal that is gone fails every
    /// keystroke.
    package nonisolated static func input(_ bytes: [UInt8], for session: String,
                                          in shared: SharedTerminalState) {
        guard let writer = shared.writer(for: session) else {
            GhosttyLog.stack.error("""
                input for terminal \(session, privacy: .public) dropped: it has no writer
                """)
            return
        }
        writer(bytes)
    }

    /// The pane's own keystrokes, by session, forwarded to the surface host.
    ///
    /// Here rather than on the host directly because the host is the seam onto an
    /// unstable API and this stack is its one owner; the app points this at the
    /// store, which drops a terminal's attention flag the moment the user types into
    /// the surface it shows. Free to claim: unlike the host's other callbacks, no
    /// part of this substrate reads input, so nothing here contends for it.
    /// Where the service's "please show this terminal" requests go.
    ///
    /// A box rather than a plain property because the service is handed its hook at
    /// construction and the frontend that answers it is wired afterwards. Pointed at
    /// `TerminalSelection` by the app; nil until then, and on a stack that could not
    /// be built there is nothing to request.
    package final class DisplayRequests {
        package var handler: (@MainActor (String?) -> Void)?
        package init() {}
        @MainActor package func call(_ session: String?) { handler?(session) }
    }

    package let displayRequests: DisplayRequests

    /// Makes every terminal opened from now on keep as much history as `store` says.
    ///
    /// Called by whoever builds the store, because the stack is built first: the
    /// store is handed this stack's service. Here rather than in the app so the
    /// knowledge of which setting feeds which part of the terminal stays in the
    /// core, where it will still be when there is no frontend to do the wiring.
    ///
    /// Weakly, and answering the default once the store is gone, so the service
    /// does not keep a store alive. On a stack that could not be built there is no
    /// service and nothing to tell.
    package func followScrollbackSetting(of store: ProjectStore) {
        ghosttyService?.scrollbackLines = { [weak store] in
            store?.scrollbackLines ?? TerminalScrollback.defaultLines
        }
    }

    package var onInput: (@MainActor (String) -> Void)? {
        get { host.onInput }
        set { host.onInput = newValue }
    }

    /// The store facing half of this substrate, bound to this stack: the job
    /// events the sidebar reads, collected on the app's poll.
    package var pollJobs: @MainActor () -> [MonitorEvent] {
        { [weak self] in self?.ghosttyService?.jobEvents() ?? [] }
    }

    /// Tears the stack down at quit: every terminal, its surface and its pane's
    /// bridge, and then the local socket server, whose socket file goes with it.
    /// Idempotent. It does not wait for the server's connection threads; each ends
    /// on its own once its socket is shut down.
    package func shutDown() {
        ghosttyService?.closeAll()
        localServer?.stop()
    }
}
