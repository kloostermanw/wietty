import Darwin
import Foundation
import WiettyCore
import WiettyShared

/// Joins a surface's `wietty-pty` to a terminal's stream.
///
/// The helper copies raw bytes between the surface's tty and a Unix socket, and this
/// owns that socket: it listens at `helperSocketPath` and accepts one client, the
/// helper. On the other side is a `TerminalStreamLink`. The payloads of `snapshot`,
/// `repaint` and `data` go to the helper unchanged and in order; a `resize` goes to
/// `onResize` and the link's end to `onEnded`, neither to the helper; bytes from the
/// helper go to `link.send` unchanged.
///
/// ## Order of events
///
/// `init` binds and listens, and returns. The link is started only when the helper
/// has connected: earlier, its snapshot and live output would have to be held for a
/// surface that is not reading yet. A `claim` before that is remembered, the last
/// one, and sent when the link starts; it is sent again to a link `reconnect` starts.
///
/// ## No buffering
///
/// A message from the link is written to the helper with a blocking write, inside
/// the link's `onMessage`, so the link reads its next frame only once the helper has
/// taken this one. A surface that stops reading therefore fills the helper's socket,
/// which holds the link's thread, which fills the link's socket, which holds the
/// server's write on the pty's thread. Nothing is held here, and nothing is lost.
///
/// ## Ends
///
/// The helper going away (the surface was destroyed) stops the link, and nothing more
/// is started after it. The link ending does not touch the helper: it is reported
/// through `onEnded`, and `reconnect(with:)` can attach a new link to the same helper.
///
/// ## Threads and descriptors
///
/// The listener is watched by a dispatch source on a queue of the bridge's own, and is
/// closed only by that source's cancel handler. The helper is read by a thread of its
/// own, which is the only one that closes the helper's socket, as it exits, holding
/// the write lock; writes to it run on the link's thread under that lock. Everything
/// else only shuts the socket down while it is open, which releases a blocked read or
/// write at once. Nothing here is on the main actor.
final class TerminalBridge: @unchecked Sendable {
    /// The raw socket `wietty-pty` is told to connect to.
    let helperSocketPath: String

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "eu.kloosterman.wietty.bridge")
    private var listenFd: Int32
    private var listenSource: DispatchSourceRead?
    private let boundFile: PrivateSocket.Identity

    private var helperFd: Int32 = -1
    /// Whether a helper has ever been accepted. Only one ever is.
    private var helperAccepted = false
    /// Whether `helperFd` is still open. Cleared only by the helper's reader thread.
    private var helperOpen = false
    /// Whether the helper is still there: accepted, and not yet gone.
    private var helperAlive = false

    private var link: any TerminalStreamLink
    /// The link that has been started, so it is started once.
    private var startedLink: ObjectIdentifier?
    /// The link the bridge has stopped last, so the helper going away after `stop()`
    /// does not stop it a second time.
    private var stoppedLink: ObjectIdentifier?
    private var lastClaim: (cols: Int, rows: Int)?
    private var stopped = false
    private var resizeHandler: (@Sendable (_ cols: Int, _ rows: Int, _ own: Bool) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?

    /// Held while a link is started or claimed through, so a claim cannot reach a
    /// link that is about to start (and drop it), and claims go out in order. Never
    /// held while a link is stopped: `stop()` waits for a callback, and a callback may
    /// call `claim`.
    private let control = NSLock()
    /// Held for each write to the helper; the close takes it to wait for one.
    private let helperWriteLock = NSLock()

    var onResize: (@Sendable (_ cols: Int, _ rows: Int, _ own: Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return resizeHandler }
        set { lock.lock(); resizeHandler = newValue; lock.unlock() }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return endHandler }
        set { lock.lock(); endHandler = newValue; lock.unlock() }
    }

    /// Binds and listens at `helperSocketPath` (mode 0600, replacing a stale file),
    /// and returns without waiting for the helper.
    init(helperSocketPath: String, link: any TerminalStreamLink) throws {
        self.helperSocketPath = helperSocketPath
        self.link = link
        let (fd, identity) = try PrivateSocket.listen(at: helperSocketPath, backlog: 1)
        listenFd = fd
        boundFile = identity

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
    }

    deinit { stop() }

    /// The listening descriptor, or -1 once stopped. For tests.
    var listeningDescriptor: Int32 {
        lock.lock(); defer { lock.unlock() }
        return listenFd
    }

    /// The helper's descriptor while it is open. For tests.
    var helperDescriptor: Int32? {
        lock.lock(); defer { lock.unlock() }
        return helperOpen ? helperFd : nil
    }

    /// Claims the grid at this size. Before the link has started it is remembered (the
    /// last one) and sent when it starts.
    func claim(cols: Int, rows: Int) {
        control.lock()
        defer { control.unlock() }
        lock.lock()
        lastClaim = (cols, rows)
        let current = link
        let started = startedLink == ObjectIdentifier(current) && !stopped
        lock.unlock()
        if started { current.claim(cols: cols, rows: rows) }
    }

    /// Makes the link again after a lost connection, keeping the helper.
    ///
    /// The old link is stopped first, which waits for a callback of it in progress
    /// unless this is called from inside one (as from `onEnded`, the expected place);
    /// nothing of it reaches the helper afterwards. The new link is started at once if
    /// the helper is connected, else when it connects, and is sent the last claim.
    func reconnect(with newLink: any TerminalStreamLink) {
        lock.lock()
        let old = link
        link = newLink
        stoppedLink = ObjectIdentifier(old)
        lock.unlock()
        old.stop()
        control.lock()
        startLinkIfReady()
        control.unlock()
    }

    /// Stops the link, closes the helper's connection and the listener, and removes the
    /// socket file. Idempotent. Does not wait for the helper: its socket is shut down
    /// first, which fails a write to it that is blocked, so the link's callback returns
    /// and the link's `stop()` does not wait on a surface that is not reading.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        helperAlive = false
        if helperOpen { shutdown(helperFd, SHUT_RDWR) }
        let current = link
        let stopLink = stoppedLink != ObjectIdentifier(current)
        stoppedLink = ObjectIdentifier(current)
        let source = listenSource
        listenSource = nil
        listenFd = -1
        lock.unlock()

        source?.cancel()
        if stopLink { current.stop() }
        PrivateSocket.unlink(helperSocketPath, ifStill: boundFile)
    }

    // MARK: The helper

    /// The listen source's event handler: the listener cannot be closed while this
    /// runs, because only that source's cancel handler closes it.
    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            // `accept` does not carry FD_CLOEXEC over: the helper is spawned by
            // libghostty, and a surface spawned later must not inherit this.
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Darwin does carry O_NONBLOCK over, and every read and write here blocks.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            // A helper that goes away mid-write must not kill the app; see
            // `TerminalRelay.accept`. Not inherited from the listener.
            var suppressSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            // One surface renders this terminal, so one helper connects. A second
            // client would interleave two inputs into one shell.
            let reject = stopped || helperAccepted
            if !reject {
                helperAccepted = true
                helperFd = fd
                helperOpen = true
                helperAlive = true
            }
            lock.unlock()
            guard !reject else { close(fd); continue }

            // The link first, so the helper's first keystrokes find it started.
            control.lock()
            startLinkIfReady()
            control.unlock()
            let thread = Thread { [self] in readHelper(fd) }
            thread.name = "eu.kloosterman.wietty.bridge.helper"
            thread.start()
        }
    }

    /// The helper's reader thread: its bytes to the link, until it goes away.
    private func readHelper(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            lock.lock()
            let current = link
            lock.unlock()
            current.send(Array(buffer[0..<count]))
        }
        helperGone(fd)
    }

    /// The surface is gone, or the bridge stopped. Closes the helper's socket, once no
    /// write uses it, and stops the link.
    private func helperGone(_ fd: Int32) {
        lock.lock()
        helperAlive = false
        if helperOpen { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        helperWriteLock.lock()
        lock.lock()
        if helperOpen {
            helperOpen = false
            close(fd)
        }
        // Read after `helperAlive` was cleared, so a link swapped in by `reconnect`
        // since is either this one or is never started.
        let current = link
        let stopLink = stoppedLink != ObjectIdentifier(current)
        stoppedLink = ObjectIdentifier(current)
        lock.unlock()
        helperWriteLock.unlock()
        if stopLink { current.stop() }
    }

    /// Writes `bytes` to the helper in full, blocking until it has taken them.
    private func writeToHelper(_ bytes: [UInt8]) {
        helperWriteLock.lock()
        defer { helperWriteLock.unlock() }
        lock.lock()
        let fd = helperFd
        let live = helperOpen
        lock.unlock()
        guard live else { return }
        var offset = 0
        let complete = bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        // The helper is gone; its reader thread sees the end and does the rest.
        if !complete {
            lock.lock()
            if helperOpen { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
        }
    }

    // MARK: The link

    /// Starts the current link if the helper is there and it has not been started.
    /// Called with `control` held.
    private func startLinkIfReady() {
        lock.lock()
        let current = link
        let id = ObjectIdentifier(current)
        guard !stopped, helperAlive, startedLink != id else { lock.unlock(); return }
        startedLink = id
        let claim = lastClaim
        lock.unlock()

        current.onMessage = { [weak self] message in self?.received(message, from: id) }
        current.onEnded = { [weak self] reason in self?.ended(reason, from: id) }
        current.start()
        if let claim { current.claim(cols: claim.cols, rows: claim.rows) }
    }

    /// On the link's thread. Blocks for as long as the helper takes the bytes.
    private func received(_ message: StreamMessage, from id: ObjectIdentifier) {
        lock.lock()
        let current = !stopped && ObjectIdentifier(link) == id
        let resize = resizeHandler
        lock.unlock()
        guard current else { return }
        switch message {
        case .snapshot(let bytes), .repaint(let bytes), .data(let bytes):
            writeToHelper(bytes)
        case let .resize(cols, rows, own):
            resize?(cols, rows, own)
        case .hello, .error, .ended:
            break
        }
    }

    private func ended(_ reason: TerminalEndReason, from id: ObjectIdentifier) {
        lock.lock()
        let current = !stopped && ObjectIdentifier(link) == id
        let handler = endHandler
        lock.unlock()
        guard current else { return }
        handler?(reason)
    }
}
