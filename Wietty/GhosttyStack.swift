import AppKit
import Foundation

/// Composition root for the terminal stack. Builds the pieces, wires the byte and
/// event routing between them, and reports a stack that cannot work through
/// `setupError`.
///
/// It always constructs. A libghostty that will not initialise or a missing bundled
/// helper is reported rather than thrown, so the app launches and can explain itself
/// instead of failing at every call site.
///
/// The host is injected so tests can drive the whole stack with no framework and
/// no Metal device. `WiettyApp` passes the real `GhosttySurfaceHost`.
@MainActor
final class GhosttyStack {
    /// The one streaming path, shared with the app's own pane. That sharing is why
    /// stopping the LAN server must not stop the hub: `stop()` cancels the flush
    /// timer permanently, so tearing the server down would leave every later local
    /// viewer silent.
    let hub = PaneStreamHub(startTimer: true)
    let service: any TerminalService
    let monitor: any SessionMonitoring
    private(set) var setupError: String?

    /// The concrete service, for the pane, which needs the selection and the
    /// views, and for teardown. Nil when the stack could not be built.
    private(set) var ghosttyService: GhosttyService?
    private let ghosttyMonitor: GhosttyMonitor?
    /// Held so the pane can ask for a session's view. The pane must not reach the
    /// host directly: it is the seam onto an unstable API and only this stack owns
    /// it.
    private let host: any TerminalSurfaceHosting

    /// The channel a remote viewer's keystrokes travel down, and the reason there
    /// is a channel at all rather than a `Task` per keystroke.
    ///
    /// The hub hands keystrokes over on its own thread and the write has to happen
    /// on the main actor, where the terminal registry lives. One unstructured
    /// `Task` per keystroke would be the obvious bridge and is the wrong one: input
    /// order is as load bearing as output order, and Tasks created in order can
    /// still run in either order. An `AsyncStream` with a single consumer
    /// delivers in yield order, so a paste arriving as several messages cannot be
    /// reassembled scrambled.
    ///
    /// Nil on a stack that could not be built, which has no service to send to.
    private let keystrokes: AsyncStream<(session: String, text: String)>.Continuation?

    /// Held only so it can be removed: an observer left registered after this
    /// stack is gone is a token `NotificationCenter` keeps forever. A `let`
    /// because `deinit` reads it, and a nonisolated `deinit` on a main actor type
    /// may only touch immutable state. `nonisolated(unsafe)` for the same reason
    /// `GhosttySurfaceHost` needs it: the token is an opaque `NSObjectProtocol`
    /// that carries no Sendable conformance, and the only access from outside the
    /// main actor is the `deinit` that hands it straight back.
    private nonisolated(unsafe) let terminationObserver: NSObjectProtocol?

    /// - Parameter helperPath: where `wietty-pty` is. Nil means it is not in
    ///   the bundle, which is a startup error rather than a per terminal one:
    ///   every surface's command would be missing.
    /// - Parameter hostFailure: why libghostty could not be initialised, or nil
    ///   when it was. Passed in rather than patched on afterwards so that ONE error
    ///   both reaches `setupError` and is thrown by every terminal action.
    ///   Reporting one reason and throwing a different one sends the user to fix
    ///   the wrong thing.
    init(host: any TerminalSurfaceHosting, helperPath: String?, hostFailure: TerminalError? = nil) {
        self.host = host
        // Both ways this stack can be born broken reduce to one question, so there
        // is one guard below and no force unwrap: is there a usable helper on a
        // libghostty that started?
        //
        // Ordered deliberately: a libghostty that will not start is the more
        // fundamental failure, and a build with that problem usually has the helper
        // problem too, so reporting the helper first would bury the real cause.
        let usableHelper: String? = hostFailure == nil
            ? helperPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            : nil
        guard let helperPath = usableHelper else {
            // The libghostty failure whenever there is one, since it suppresses
            // `usableHelper` above; the helper otherwise, which is the only other
            // way to reach this branch.
            let failure = hostFailure ?? .ghosttyHelperMissing
            setupError = failure.errorDescription
            service = UnavailableTerminalService(error: failure)
            monitor = InactiveMonitor()
            ghosttyService = nil
            ghosttyMonitor = nil
            keystrokes = nil
            // No terminals to tear down, so nothing to observe.
            terminationObserver = nil
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

        let hub = self.hub
        let monitor = GhosttyMonitor(host: host)
        let service = GhosttyService(
            host: host,
            helperPath: helperPath,
            // Straight into the hub, off the main actor, in stream order. This is
            // the whole reason Wietty owns the PTY: the same bytes that reach
            // the surface reach every remote viewer.
            onOutput: { session, bytes in hub.write(session: session, bytes: bytes) },
            // The grid, to the same hub. A viewer learns its size in the paint it
            // gets on attach and from nothing else, so without this a window resize
            // leaves every already attached viewer rendering reflowed bytes against
            // the old grid until it reattaches. `noteSize` dedupes and does the
            // delivery on its own queue, so this costs nothing when a report does not
            // move the grid. Into the hub rather than back into the service, for the
            // same reason the census and the paint go through `shared`: this closure
            // runs on the main actor and the hub is lock guarded, so the direction is
            // the safe one.
            onResized: { session, size in hub.noteSize(session: session, size) },
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
            onTerminated: { session in monitor.emit([.terminated(sessionId: session)]) })

        // Both hooks read `shared`, never the service itself. The hub calls them
        // from its own delivery queue and `GhosttyService` is main actor isolated,
        // so reaching into it here would either deadlock or need an
        // `assumeIsolated` that is simply untrue. `SharedTerminalState` exists for
        // exactly these two questions.
        let shared = service.shared
        // Asked on attach, so a session id whose terminal is gone is answered with
        // `ended` rather than a socket that opens and then never speaks. It cannot
        // fail: the registry is in this process, so there is never an `.unknown` to
        // report.
        hub.onSessionCensus = { .sessions(shared.liveSessions) }
        // The initial screen for a viewer attaching to a live terminal. Monochrome
        // with an approximated cursor by necessity: `ScreenSnapshot` documents why.
        //
        // An absent snapshot returns nothing, which the hub treats as a capture
        // that failed rather than as an empty screen: the viewer keeps whatever it
        // had and the live byte stream brings it current. That is the honest
        // answer, because the alternative is painting a blank screen over a
        // terminal that has content.
        hub.onPaint = { session in
            guard let snapshot = shared.snapshot(for: session) else { return [] }
            return PaneStreamHub.paintMessages(rows: snapshot.rows,
                                               cursorX: snapshot.cursorX,
                                               cursorY: snapshot.cursorY,
                                               cols: snapshot.cols,
                                               rows: snapshot.rows.count)
        }
        // A remote viewer's keystrokes take the same path as a local one's: into
        // the pty master, where the ordering guarantee lives. They go through the
        // stream rather than straight into a `Task` for the reason its own comment
        // gives.
        let (input, continuation) =
            AsyncStream.makeStream(of: (session: String, text: String).self)
        keystrokes = continuation
        hub.onSend = { session, text in continuation.yield((session: session, text: text)) }
        // Weakly, so the consumer cannot keep the service, and so its terminals,
        // alive after this stack is gone. A stream that outlives its service drains
        // to nothing rather than resurrecting it.
        Task { @MainActor [weak service] in
            for await keystroke in input {
                // Stops rather than draining: a service that is gone cannot come
                // back, so every later keystroke has the same answer.
                guard let service else { break }
                do {
                    try await service.send(sessionId: keystroke.session, text: keystroke.text)
                } catch {
                    // Not an alert: a keystroke that failed is not worth
                    // interrupting the user for, and a terminal that is gone fails
                    // every one of them. Recorded rather than discarded, because a
                    // row that had stopped accepting input was otherwise
                    // indistinguishable from one being typed into correctly. The
                    // same rule `TmuxStack.onSend` follows.
                    GhosttyLog.stack.error("""
                        keystroke to terminal \(keystroke.session, privacy: .public) failed: \
                        \(String(describing: error), privacy: .public)
                        """)
                }
            }
        }
        // The hub holds the escape state needed to tell a real bell from an OSC
        // terminator, but libghostty has already parsed both, so the surface's
        // bell is the one that is reported and this hook stays unwired.

        // Every terminal is torn down when the app quits, because nothing else
        // will. A PTY the app spawned cannot outlive it usefully, and an object
        // still alive at exit gets no `deinit`, so without this the relay's socket
        // file is left in the temp directory for an hour until `clearStaleSockets`
        // sweeps it, and the shell only dies because its master happened to close.
        // Synchronous delivery is required, hence `queue: nil`: an
        // `OperationQueue` hop may not run before the process is gone. The same
        // notification `ITermMonitor` shuts itself down on.
        //
        // Weakly, so an observer that outlives this stack cannot resurrect the
        // service and the terminals hanging off it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak service] _ in
            MainActor.assumeIsolated { service?.closeAll() }
        }

        self.service = service
        self.monitor = monitor
        self.ghosttyService = service
        self.ghosttyMonitor = monitor
    }

    /// Ends the keystroke stream, so its consumer stops rather than waiting on a
    /// continuation nothing holds any more.
    deinit {
        keystrokes?.finish()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    /// The pane's own keystrokes, by session, forwarded to the surface host.
    ///
    /// Here rather than on the host directly because the host is the seam onto an
    /// unstable API and this stack is its one owner; the app points this at the
    /// store, which drops a terminal's attention flag the moment the user types into
    /// the surface it shows. Free to claim: unlike the host's other callbacks, no
    /// part of this substrate reads input, so nothing here contends for it.
    var onInput: (@MainActor (String) -> Void)? {
        get { host.onInput }
        set { host.onInput = newValue }
    }

    /// The store facing half of this substrate, bound to this stack.
    ///
    /// The poll does two things, because it is the app's one main actor heartbeat on
    /// this substrate. It collects the job events the sidebar reads, and it refreshes
    /// the screen a remote viewer's first frame is painted from: the hub asks for
    /// that paint on its own delivery queue and cannot wait for a hop, so something
    /// on the main actor has to keep it current. See
    /// `GhosttyService.refreshSnapshots`.
    var pollJobs: @MainActor () -> [MonitorEvent] {
        { [weak self] in
            guard let service = self?.ghosttyService else { return [] }
            service.refreshSnapshots()
            return service.jobEvents()
        }
    }

    /// The view a session's surface renders into, for the pane. Nil for a session
    /// with no surface, which is every session on a stack that failed to build.
    ///
    /// The pane goes through here rather than holding the host itself: the host is
    /// the seam onto an unstable API, and one owner is the point of the seam.
    func surfaceView(for session: String) -> NSView? { host.view(id: session) }

    /// How old a socket file has to be before this considers it abandoned.
    ///
    /// An hour, which is far longer than the milliseconds between a relay binding
    /// its socket and `wietty-pty` connecting to it, and far shorter than the
    /// lifetime of the crashed run whose leftovers this exists for. Nothing is lost
    /// by being late: `TerminalRelay` unlinks before it binds, so a stale file never
    /// blocks a terminal in the first place.
    static let staleSocketAge: TimeInterval = 3600

    /// Removes socket files a crashed run left in the temp directory.
    ///
    /// Housekeeping only: the paths are derived from session ids that no longer
    /// exist, so nothing else will ever clean them up. `TerminalRelay` unlinks
    /// before it binds, so a leftover file is never in a new terminal's way.
    ///
    /// The temp directory is shared, so the whole difficulty is telling whose
    /// socket is whose. Age is the answer, because the name cannot be: the path
    /// budget is `sockaddr_un.sun_path`, 104 bytes including the terminator, and it
    /// is already tight enough that `TerminalRelay.socketPath` truncates the session
    /// id to 12 hex digits. Encoding an owner pid would be more precise and there is
    /// no room for it.
    ///
    /// Without that predicate this cannot be called safely at all. Every socket in
    /// the directory would go, including those of a second Wietty running
    /// alongside this one (a Debug build next to the installed app) and those of a
    /// relay in this very process that has bound its socket but whose helper has not
    /// connected yet, which unlinks the path the helper is about to reach.
    ///
    /// A file whose age cannot be read is left alone: an unlink decided on missing
    /// information is the one this must not make.
    func clearStaleSockets() {
        let directory = NSTemporaryDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        let cutoff = Date(timeIntervalSinceNow: -Self.staleSocketAge)
        for name in names where name.hasPrefix("ipx-") && name.hasSuffix(".sock") {
            let path = directory + name
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let modified = attributes?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            unlink(path)
        }
    }
}
