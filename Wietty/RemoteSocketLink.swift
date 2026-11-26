import Foundation
import WiettyShared

/// A terminal's stream from another Mac's `RemoteServer`, over the package's
/// `TerminalStreamConnection` (`WS /attach`, protocol version 2, resize mode `.reflow`),
/// built from a `RemoteConnection` and a session id through the package's attach URL.
///
/// The package's connection does most of what `TerminalStreamLink` asks: it consumes the
/// `hello`, turns `ended` and `error` into one end, reads one frame at a time and asks
/// for the next only once the current one has been delivered, so a callback that blocks
/// holds the server back. What it does not give is the protocol's `stop()`: called from
/// another thread, it lets a callback already past its check run after it returns. This
/// link adds that with a callback lock and a stopped flag, as `LocalSocketLink` does.
///
/// ## Threads
///
/// Every callback runs on one serial queue the link owns, never the main queue and
/// never a global one (the bridge blocks inside `onMessage`). The package wraps it in a
/// private serial queue of its own that targets it. Each callback runs under the
/// callback lock and only while the link is live, checked under that lock, so a
/// `stop()` either waits for it or prevents it.
///
/// `start()` and `claim` return at once. `send` returns at once too: the package hands
/// input to URLSession, which queues it without a bound, so unlike `LocalSocketLink`'s
/// it never waits for a server that is not reading.
///
/// ## Ends
///
/// The reasons are the package's, passed on unchanged: `ended` is `.sessionEnded`,
/// `error` is `.refused(code, message)`, a server older than version 2 is
/// `.serverTooOld`, a newer one `.refused(code: "protocol", ...)`, and a failed connect,
/// a refused upgrade (a wrong token among them) or a dropped socket `.connectionLost`.
/// `onEnded` runs once, on the link's queue. After an end or a stop, `send` and `claim`
/// are dropped.
///
/// ## Once
///
/// A link is used once. After an end or a stop it does not start again; the owner makes
/// a new one.
///
/// The token travels inside the attach URL the package builds. The link keeps no copy
/// of it, logs nothing and puts nothing of it into an end reason.
final class RemoteSocketLink: TerminalStreamLink, @unchecked Sendable {
    private enum Phase {
        case idle, live, ended, stopped
    }

    let session: String

    private let queue: DispatchQueue
    /// Set on `queue` only, and per link: a callback of another link that stops this one
    /// is not inside this one's callback, and must wait for it.
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let connection: TerminalStreamConnection

    /// Guards everything below.
    private let lock = NSLock()
    private var phase = Phase.idle
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var arrivalCount = 0

    /// Held for each callback; `stop()` takes it to wait for one in progress.
    private let callbackLock = NSLock()

    init(connection remote: RemoteConnection, session: String) {
        self.session = session
        let queue = DispatchQueue(label: "eu.kloosterman.wietty.remote-link")
        queue.setSpecific(key: queueKey, value: 1)
        self.queue = queue
        connection = TerminalStreamConnection(connection: remote, sessionId: session, resize: .reflow,
                                              callbackQueue: queue)
        // Set before `start()`, as the package asks, and never again.
        connection.onMessage = { [weak self] message in self?.deliver(message) }
        connection.onEnded = { [weak self] reason in self?.end(reason) }
    }

    /// Called on the link's queue. See the protocol for what it may do.
    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    /// Called on the link's queue, once.
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }

    /// Whether the link has started and neither ended nor stopped.
    var isLive: Bool { lock.withLock { phase == .live } }

    /// How many messages the package has handed to the link, delivered or not. For
    /// tests: it shows whether the package read on while a callback was blocked.
    var arrivals: Int { lock.withLock { arrivalCount } }

    /// Opens the socket and returns at once. Does nothing when started already, ended
    /// or stopped.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .idle else { return }
        phase = .live
        // Under the lock, so a `stop()` cannot fall between the phase and the start and
        // leave a socket open behind a stopped link. The package delivers nothing from
        // inside `start()` (even a URL it cannot build ends the stream through its
        // queue), so nothing here comes back for this lock.
        connection.start()
    }

    /// Closes the connection. Fires no `onEnded`. Idempotent.
    ///
    /// Waits for a callback that is running, so that after it returns none runs and
    /// none comes; called from inside a callback it cannot wait for that one, returns
    /// at once, and nothing comes after it either. It waits for nothing else: the
    /// package cancels its socket without waiting for the server.
    func stop() {
        lock.withLock { phase = .stopped }
        connection.stop()
        guard DispatchQueue.getSpecific(key: queueKey) == nil else { return }
        callbackLock.lock()
        callbackLock.unlock()
    }

    /// Input for the remote terminal. Once the server's hello has been accepted it goes
    /// out as given, split by the package into `data` messages of at most 64 KiB. Input
    /// sent between `start()` and the hello is held by the package, up to 64 KiB in all,
    /// the oldest bytes dropped first, so a paste made in that window can lose its
    /// start. Dropped before `start()` and after an end or a stop. Never waits.
    func send(_ bytes: [UInt8]) {
        guard isLive else { return }
        // A stop that lands here is caught by the package, which drops writes after
        // its own stop.
        connection.send(bytes)
    }

    /// Claims the grid at this size; `own` is sent as false. Never waits. Dropped before
    /// `start()` and after an end or a stop.
    func claim(cols: Int, rows: Int) {
        guard isLive else { return }
        connection.claim(cols: cols, rows: rows)
    }

    /// For tests only: returns once every block already queued on the link's queue when
    /// it is called has run, so every callback the package had queued by then has run
    /// or been dropped. It does not wait for frames still in URLSession or on the
    /// socket, nor for callbacks the package queues after it. Never call it on the
    /// link's queue: it would wait for itself.
    func waitForCallbacks() {
        queue.sync {}
    }

    // MARK: From the package

    /// Calls `onMessage`, under the callback lock, unless the link is over. The package's
    /// `onMessage` calls this on the link's queue. Not private so that a test can hand
    /// the link a message after `stop()`, which the package itself would drop, and so
    /// test the link's own guard.
    func deliver(_ message: StreamMessage) {
        lock.withLock { arrivalCount += 1 }
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard let handler = lock.withLock({ phase == .live ? messageHandler : nil }) else { return }
        handler(message)
    }

    /// Ends the link for `reason`, once, unless it was stopped. The package's `onEnded`
    /// calls this on the link's queue. Not private for the same reason as `deliver`.
    func end(_ reason: TerminalEndReason) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        let handler: (@Sendable (TerminalEndReason) -> Void)? = lock.withLock {
            guard phase == .live else { return nil }
            phase = .ended
            return endHandler
        }
        handler?(reason)
    }
}
