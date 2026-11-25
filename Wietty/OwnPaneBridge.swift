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
/// `.sessionEnded` is the terminal stopping: the service's own end path (the stopped
/// screen) takes over and nothing is made again. `.refused` and `.serverTooOld`
/// cannot happen between two halves of one process; they are logged and not
/// retried. The helper going away means the surface went away: the bridge is
/// stopped.
///
/// **Threads.** None of this runs on the main actor, and none of it needs to: the
/// bridge calls `onEnded` on the link's thread and `onHelperGone` on its helper
/// thread, and both return at once (a reconnect never blocks, a delayed one and the
/// stop after the helper went are put on a queue of this type's own). So `stop()`,
/// which the host calls on the main actor and which waits for a running callback
/// of the bridge, waits for nothing that could wait for the main thread.
/// `onResize` is left unset: the surface still reports its own grid, and
/// `GhosttyService` resizes the pty from that report.
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
            lock.unlock()
            if delay <= 0 {
                reconnect()
            } else {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reconnect() }
            }
        case .sessionEnded:
            // The terminal stopped. The surface keeps its last screen; the stopped
            // screen comes from the service's own end path.
            break
        case .serverTooOld, .refused:
            Self.log.error("""
                the pane of terminal \(self.session, privacy: .public) was refused by \
                this app's own stream server (\(String(describing: reason), privacy: .public)); \
                it is not reconnected
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

    /// - Parameter helperPath: the bundled `wietty-pty`.
    /// - Parameter serverPath: the app's `LocalStreamServer` socket.
    init(helperPath: String, serverPath: String, backoff: ReconnectBackoff = .standard) {
        self.helperPath = helperPath
        self.serverPath = serverPath
        self.backoff = backoff
    }

    /// Builds and starts listening for the bridge of `session`, and returns the
    /// command the surface must run: the helper, told the bridge's socket.
    func open(session: String) throws -> String {
        let path = try LocalSocketPaths.bridge(Self.nextSequence())
        let bridge = try OwnPaneBridge(session: session, serverPath: serverPath,
                                       helperSocketPath: path, backoff: backoff)
        bridges[session]?.stop()
        bridges[session] = bridge
        return Self.command(helper: helperPath, socket: path)
    }

    /// Stops the bridge of `session`, which unlinks its socket. Nothing to do for a
    /// session with none.
    func close(session: String) {
        bridges.removeValue(forKey: session)?.stop()
    }

    func closeAll() {
        let all = bridges.values
        bridges = [:]
        for bridge in all { bridge.stop() }
    }

    /// The bridge of `session`. For tests.
    func bridge(for session: String) -> OwnPaneBridge? { bridges[session] }

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
