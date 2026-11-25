import Foundation
import OSLog
import WiettyCore
import WiettyShared

/// How soon a pane's link is made again after it was lost.
///
/// The first retry is at once, then after `initial`, doubling up to `cap`. The count
/// starts over once a link has stayed up for `resetAfter`. A pane that is still
/// stalled is dropped again by the server within its write deadline, so without the
/// growing wait it would reconnect in a tight loop, each time costing the hub's
/// queue a snapshot it cannot deliver.
struct ReconnectBackoff: Sendable {
    var initial: TimeInterval = 0.25
    var cap: TimeInterval = 5
    var resetAfter: TimeInterval = 10

    static let standard = ReconnectBackoff()

    /// The wait before retry number `attempt`, counted from 0.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // Doubling from `initial`, without ever computing a power that overflows.
        var delay = initial
        for _ in 1..<min(attempt, 32) where delay < cap { delay *= 2 }
        return min(delay, cap)
    }
}

/// The bridge of one local terminal's surface, and the policy that keeps it on the
/// stream: a `TerminalBridge` whose link is a `LocalSocketLink` to this app's
/// `LocalStreamServer`, for one session.
///
/// **Ends.** A link that ends as `.connectionLost` while the terminal is still alive
/// (the server drops a pane that reads nothing for 5 seconds during a control
/// message) is replaced by a fresh link, from `onEnded` and nowhere else, after the
/// wait `ReconnectBackoff` gives. The new link's attach brings a snapshot, which
/// begins with a full reset, so the surface starts over from the server's screen.
/// `.sessionEnded` is the terminal stopping: the bridge is stopped, so the helper
/// exits with the child as it did when the relay owned its socket and no process,
/// thread or socket file is kept for a stopped row; the surface stays, with its last
/// screen, until the row is closed or restarted, and the stopped screen comes from
/// the service's own end path. `.refused` means the server would not serve this pane
/// (`busy`: it serves as many as it can); it is logged and not retried, and the
/// terminal's pty is still read once `GhosttyService`'s wait for the pane runs out,
/// so remote viewers keep it. `.serverTooOld` cannot happen between two halves of one
/// process; it is logged likewise. The helper going away means the surface went away:
/// the bridge is stopped.
///
/// **Threads.** None of this runs on the main actor, and none of it needs to: the
/// bridge calls `onEnded` on the link's thread and `onHelperGone` on its helper
/// thread, and both return at once (a reconnect never blocks, a delayed one and the
/// stop after the helper went are put on a queue of this type's own). So `stop()`,
/// which the host calls on the main actor and which waits for a running callback
/// of the bridge, waits for nothing that could wait for the main thread.
///
/// **The grid.** The bridge's `onResize` and `onLinkLost` here are for the pane's
/// `OwnPaneGrid`, which `PaneBridges` wires to them: both are called on the link's
/// thread and must hop to the main actor asynchronously.
final class OwnPaneBridge: @unchecked Sendable {
    private static let log = Logger(subsystem: "eu.kloosterman.wietty", category: "own-pane")

    let session: String
    let bridge: TerminalBridge
    private let backoff: ReconnectBackoff
    private let now: @Sendable () -> TimeInterval
    private let makeLink: @Sendable () -> any TerminalStreamLink
    private let queue = DispatchQueue(label: "eu.kloosterman.wietty.own-pane")

    private let lock = NSLock()
    private var stopped = false
    /// Retries since the last link that stayed up for `backoff.resetAfter`.
    private var attempts = 0
    /// When the current link was handed to the bridge.
    private var linkSince: TimeInterval
    private var linksMade = 1
    private var linkLostHandler: (@Sendable () -> Void)?

    /// The link was lost and is being made again. Called on the link's thread, before
    /// the reconnect is asked for, so a hop to the main queue made here lands ahead of
    /// anything the new link delivers. Must not wait on the main thread.
    ///
    /// Only for `.connectionLost`, the one end after which there is a next link: a
    /// claim sent to the link that ended may never be answered, so the owner of the
    /// grid's state starts its count over here.
    var onLinkLost: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return linkLostHandler }
        set { lock.lock(); linkLostHandler = newValue; lock.unlock() }
    }

    /// - Parameter serverPath: the app's `LocalStreamServer` socket.
    /// - Parameter helperSocketPath: where the bridge listens for `wietty-pty`.
    /// - Parameter now: a monotonic clock in seconds, for the backoff's reset.
    /// - Parameter makeLink: builds each link; a `LocalSocketLink` to `serverPath`
    ///   for `session` unless a test says otherwise.
    init(session: String, serverPath: String, helperSocketPath: String,
         backoff: ReconnectBackoff = .standard,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeLink: (@Sendable () -> any TerminalStreamLink)? = nil) throws {
        self.session = session
        self.backoff = backoff
        self.now = now
        let make = makeLink ?? { LocalSocketLink(path: serverPath, session: session) }
        self.makeLink = make
        linkSince = now()
        bridge = try TerminalBridge(helperSocketPath: helperSocketPath, link: make())
        bridge.onEnded = { [weak self] reason in self?.linkEnded(reason) }
        bridge.onHelperGone = { [weak self] in self?.helperGone() }
    }

    /// How many links have been made, the first included. For tests.
    var linkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return linksMade
    }

    /// Stops the bridge, which unlinks its socket, and every retry after it.
    /// Idempotent. Waits only for a callback of the bridge that is running, and
    /// those return at once.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        bridge.stop()
    }

    /// On the link's thread; returns at once.
    private func linkEnded(_ reason: TerminalEndReason) {
        switch reason {
        case .connectionLost:
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            if now() - linkSince >= backoff.resetAfter { attempts = 0 }
            let delay = backoff.delay(forAttempt: attempts)
            attempts += 1
            let lost = linkLostHandler
            lock.unlock()
            lost?()
            if delay <= 0 {
                reconnect()
            } else {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reconnect() }
            }
        case .sessionEnded:
            // The terminal stopped. Off this callback: the stop waits for a running
            // callback of the bridge, and this is one.
            queue.async { [weak self] in self?.stop() }
        case .serverTooOld, .refused:
            Self.log.error("""
                the pane of terminal \(self.session, privacy: .public) was refused by \
                this app's own stream server (\(String(describing: reason), privacy: .public)); \
                it is not reconnected, and the terminal is read without it
                """)
        }
    }

    /// Hands the bridge a fresh link, unless stopped meanwhile. Never blocks.
    private func reconnect() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        linkSince = now()
        linksMade += 1
        lock.unlock()
        bridge.reconnect(with: makeLink())
    }

    /// On the bridge's helper thread: the surface is gone. Stopped off that thread,
    /// so nothing the helper thread is still doing is waited on.
    private func helperGone() {
        queue.async { [weak self] in self?.stop() }
    }
}

/// Every local surface's `OwnPaneBridge`, keyed by session, and the command that
/// joins a surface to its bridge.
///
/// Owned by `GhosttySurfaceHost`, which asks for a bridge before it creates a
/// surface and stops it when it destroys one.
@MainActor
final class PaneBridges {
    /// Bridge socket sequence numbers, process wide, so that two of these (the tests
    /// build several in the app's own process) never bind the same path. On the main
    /// actor, as every instance is.
    private static var lastSequence = 0

    let helperPath: String
    let serverPath: String
    private let backoff: ReconnectBackoff
    private var bridges: [String: OwnPaneBridge] = [:]
    private var grids: [String: OwnPaneGrid] = [:]

    /// - Parameter helperPath: the bundled `wietty-pty`.
    /// - Parameter serverPath: the app's `LocalStreamServer` socket.
    init(helperPath: String, serverPath: String, backoff: ReconnectBackoff = .standard) {
        self.helperPath = helperPath
        self.serverPath = serverPath
        self.backoff = backoff
    }

    /// Builds and starts listening for the bridge of `session`, with the `OwnPaneGrid`
    /// that claims the grid through it, and returns the command the surface must run:
    /// the helper, told the bridge's socket.
    ///
    /// - Parameter impose: shows a grid in the surface's view (nil: the pane's own
    ///   size); `TerminalSurfaceHosting.impose(grid:on:)` for this session.
    func open(session: String,
              impose: @escaping @MainActor (TerminalSize?) -> Void = { _ in }) throws -> String {
        let path = try LocalSocketPaths.bridge(Self.nextSequence())
        let bridge = try OwnPaneBridge(session: session, serverPath: serverPath,
                                       helperSocketPath: path, backoff: backoff)
        let grid = OwnPaneGrid(claim: { [weak bridge] size in
            bridge?.bridge.claim(cols: size.cols, rows: size.rows) ?? false
        }, impose: impose)
        // From the link's thread to the main actor, asynchronously and never waiting
        // (the bridge's threading rule). One main queue, so the hops keep the
        // stream's order, and a lost link's lands ahead of the next link's first
        // `resize` (`onLinkLost`).
        bridge.bridge.onResize = { [weak grid] cols, rows, own in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    grid?.resizeReceived(TerminalSize(cols: cols, rows: rows), own: own)
                }
            }
        }
        bridge.onLinkLost = { [weak grid] in
            DispatchQueue.main.async { MainActor.assumeIsolated { grid?.linkLost() } }
        }
        close(session: session)
        bridges[session] = bridge
        grids[session] = grid
        return Self.command(helper: helperPath, socket: path)
    }

    /// Stops the bridge of `session`, which unlinks its socket, and its grid. Nothing
    /// to do for a session with none.
    func close(session: String) {
        grids.removeValue(forKey: session)?.stop()
        bridges.removeValue(forKey: session)?.stop()
    }

    func closeAll() {
        let all = bridges.values
        for grid in grids.values { grid.stop() }
        grids = [:]
        bridges = [:]
        for bridge in all { bridge.stop() }
    }

    /// The bridge of `session`. For tests.
    func bridge(for session: String) -> OwnPaneBridge? { bridges[session] }

    /// The grid of `session`'s pane: what the surface's container, its metrics and
    /// the user's actions are told to.
    func grid(for session: String) -> OwnPaneGrid? { grids[session] }

    /// `'<helper>' '<socket>'`: each path in single quotes, an embedded single quote
    /// written `'\''`.
    ///
    /// libghostty hands a surface's `command` to a shell: measured, it runs
    /// `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c "exec -l <command>"`.
    /// So an unquoted path with a space, such as an app installed as
    /// `/Applications/Wietty 2.app`, would become two words and the helper would be
    /// told the wrong socket. Single quotes make every byte but the quote itself
    /// literal in a POSIX shell, so the surface runs exactly one executable with
    /// exactly one argument (`GhosttyVtCoexistenceTests` checks it on a real surface).
    nonisolated static func command(helper: String, socket: String) -> String {
        quoted(helper) + " " + quoted(socket)
    }

    nonisolated static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func nextSequence() -> Int {
        lastSequence += 1
        return lastSequence
    }
}

/// One surface's `PaneGrid`, carried out: claims go to the bridge, imposed grids to
/// the host, the debounce is a main queue timer, and the time is the system's uptime.
///
/// Thin on purpose: every decision is `PaneGrid`'s, tested without any of this.
/// All of it runs on the main actor. The bridge's callbacks reach it through
/// asynchronous hops (`PaneBridges.open`), and `claim` never blocks.
///
/// Told by the host: the grid that fits the pane as the pane's size or the surface's
/// metrics change, nil when the surface leaves the window (`paneChanged`), and every
/// key, click, paste or drop (`userActed`).
@MainActor
final class OwnPaneGrid {
    private var model: PaneGrid
    private let claim: (TerminalSize) -> Bool
    private let impose: @MainActor (TerminalSize?) -> Void
    private let clock: () -> UInt64
    private var onDisplay = false
    private var debounce: DispatchWorkItem?
    private var stopped = false

    /// - Parameter claim: sends a claim; whether the bridge accepted it.
    /// - Parameter impose: shows a grid in the view, nil for the pane's own size.
    init(debounce: UInt64 = 50_000_000,
         claim: @escaping (TerminalSize) -> Bool,
         impose: @escaping @MainActor (TerminalSize?) -> Void,
         clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        model = PaneGrid(debounce: debounce)
        self.claim = claim
        self.impose = impose
        self.clock = clock
    }

    /// Whether the pane owns the grid. For tests.
    var isOwner: Bool { model.isOwner }

    /// The grid that fits the pane now, or nil when the surface is not on display.
    func paneChanged(ownGrid: TerminalSize?) {
        guard !stopped else { return }
        if let ownGrid {
            let now = clock()
            if onDisplay {
                apply(model.ownGridChanged(ownGrid, now: now))
            } else {
                onDisplay = true
                apply(model.cameOnDisplay(ownGrid, now: now))
            }
        } else if onDisplay {
            onDisplay = false
            model.wentOffDisplay()
        }
    }

    /// A key, a click, a paste or a drop in the surface.
    func userActed() {
        guard !stopped else { return }
        apply(model.userActed(now: clock()))
    }

    /// A `resize` from the server, after the hop to the main actor.
    func resizeReceived(_ grid: TerminalSize, own: Bool) {
        guard !stopped else { return }
        apply(model.resizeReceived(grid, own: own))
    }

    /// The link was lost and is being made again, after the hop to the main actor.
    func linkLost() {
        guard !stopped else { return }
        apply(model.linkEnded(now: clock()))
    }

    /// Nothing more is claimed or imposed. Idempotent.
    func stop() {
        stopped = true
        debounce?.cancel()
        debounce = nil
    }

    private func apply(_ action: PaneGrid.Action) {
        guard !stopped else { return }
        switch action {
        case .none:
            break
        case .claim(let grid):
            apply(claim(grid) ? model.claimAccepted() : model.claimRefused())
        case .scheduleDebounce(let after):
            debounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.debounce = nil
                    self.apply(self.model.debounceFired(now: self.clock()))
                }
            }
            debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(min(after, UInt64(Int.max)))),
                                          execute: item)
        case .impose(let grid):
            impose(grid)
        }
    }
}
