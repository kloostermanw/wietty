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
/// ## Using it from the main actor
///
/// `init`, `claim` and `reconnect` never block: none of them waits for a write to the
/// helper or to the server. `stop()` waits only for an `onResize` or `onEnded` that is
/// running (see `stop()`). The callbacks run on threads of the bridge and its link,
/// never on the main thread, and must never wait synchronously on the main thread:
/// hop with `DispatchQueue.main.async` or a `Task`, never `.sync`. The reason is the
/// surface. Its pty read thread can wait on a mailbox only the main thread drains
/// (a title change, the clipboard, the bell), and while it waits it does not read the
/// helper, so a write to the helper does not return. A callback that waits on the
/// main thread, while the main thread waits on that callback (in `stop()`), or on a
/// write to the helper, would never return.
///
/// ## Order of events
///
/// `init` binds and listens, and returns. The link is started only when the helper
/// has connected: earlier, its snapshot and live output would have to be held for a
/// surface that is not reading yet. Claims made while no link is live are kept (see
/// `claim`) and sent to the next link that starts.
///
/// ## No buffering
///
/// A message from the link is written to the helper with a blocking write, inside
/// the link's `onMessage`, so the link reads its next frame only once the helper has
/// taken this one. A surface that stops reading therefore fills the helper's socket,
/// which holds the link's thread, which fills the link's socket, which holds the
/// server's write on the pty's thread. Nothing is held here, and nothing is lost.
/// Input runs the other way under a bound of the link's: the helper's thread waits in
/// `link.send` while the server is not reading, so the helper and the surface wait
/// too, and no more than the link's bound of input is held.
///
/// ## Ends
///
/// The helper going away (the surface was destroyed) stops the link, nothing more is
/// started after it, and `onHelperGone` is called once. The link ending does not touch
/// the helper: it is reported through `onEnded`, and `reconnect(with:)` can attach a
/// new link to the same helper. Bytes read from the helper while no link is live
/// (between an end and the reconnect) are dropped, as the link drops them.
///
/// The owner must call `stop()`, also after `onHelperGone`. `deinit` alone does not
/// end a bridge whose helper is connected: the thread reading the helper keeps the
/// bridge alive until the helper goes away.
///
/// ## Threads and descriptors
///
/// The listener is watched by a dispatch source on a queue of the bridge's own, and is
/// closed only by that source's cancel handler: as soon as the helper has been accepted
/// (it accepts one, and holds no descriptor for it after), or at `stop()` before that. The helper is read by a thread of its
/// own, which is the only one that closes the helper's socket, as it exits, holding
/// the write lock; writes to it run on the link's thread under that lock. Everything
/// else only shuts the socket down while it is open, which releases a blocked read or
/// write at once. A link that `reconnect` replaced is stopped on a queue of the
/// bridge's own. Nothing here is on the main actor.
final class TerminalBridge: @unchecked Sendable {
    /// The raw socket `wietty-pty` is told to connect to.
    let helperSocketPath: String

    /// The most claims kept while no link is live; beyond it the oldest is dropped.
    /// Large, because a dropped claim is one the owner counted and the server never
    /// answers: a window dragged for seconds while a reconnect backs off makes hundreds.
    static let maxPendingClaims = 4096
    /// The grid sizes the hub accepts; it ignores, and never answers, anything else.
    static let claimRange = 1...10_000
    /// How long accepting pauses when the process is out of descriptors or memory.
    static let acceptRetryDelay: DispatchTimeInterval = .milliseconds(100)

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "eu.kloosterman.wietty.bridge")
    /// Where a link `reconnect` replaced is stopped, since its `stop()` waits for a
    /// callback that may be blocked on the helper.
    private let retiring = DispatchQueue(label: "eu.kloosterman.wietty.bridge.retiring")
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
    /// The link that has started and not ended: claims go straight to it.
    private var liveLink: ObjectIdentifier?
    /// The link the bridge has stopped last, so it is not stopped twice.
    private var stoppedLink: ObjectIdentifier?
    private var pendingClaims: [(cols: Int, rows: Int)] = []
    private var stopped = false
    private var resizeHandler: (@Sendable (_ cols: Int, _ rows: Int, _ own: Bool) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var helperGoneHandler: (@Sendable () -> Void)?

    /// Held while a link is started or claimed through, so a claim cannot reach a link
    /// that is about to start, and claims go out in order. Nothing that can block is
    /// done under it: a link's `start` and `claim` return at once.
    private let control = NSLock()
    /// Held for each write to the helper; the close takes it to wait for one, and the
    /// check of which link may write is made under it.
    private let helperWriteLock = NSLock()
    /// Calls waiting to take `helperWriteLock`. For tests, which need to know that a
    /// write is queued behind another before they race it. Counted only when
    /// `countsWaitingWrites` is set, so the write path the app takes for every message
    /// pays nothing for it.
    private var helperWritersWaiting = 0
    private let countsWaitingWrites: Bool

    /// A `resize` from the server: the grid in force, and whether this pane claimed it.
    /// Called on the link's thread, one at a time with the stream. Must not wait
    /// synchronously on the main thread (see the type's doc); `stop()` waits for it.
    var onResize: (@Sendable (_ cols: Int, _ rows: Int, _ own: Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return resizeHandler }
        set { lock.lock(); resizeHandler = newValue; lock.unlock() }
    }

    /// The current link ended. Called on the link's thread, once per link. The helper
    /// is kept; call `reconnect(with:)` for a new link (from here is fine, it never
    /// blocks). Must not wait synchronously on the main thread; `stop()` waits for it.
    ///
    /// The owner resets its count of unanswered claims here (replaces its
    /// `GridOwnership`): a claim sent to the link that ended may never be answered.
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return endHandler }
        set { lock.lock(); endHandler = newValue; lock.unlock() }
    }

    /// The helper went away (the surface was destroyed) and the link was stopped.
    /// Called once, on the bridge's helper thread. The owner must still call `stop()`.
    /// Must not wait synchronously on the main thread. It is not called for a helper
    /// that `stop()` disconnected, but one that went away by itself may be reported
    /// just after `stop()` has returned (`stop()` does not wait for this callback); an
    /// owner that has stopped the bridge ignores it.
    var onHelperGone: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return helperGoneHandler }
        set { lock.lock(); helperGoneHandler = newValue; lock.unlock() }
    }

    /// Binds and listens at `helperSocketPath` (mode 0600, replacing a stale file),
    /// and returns without waiting for the helper. `countsWaitingWrites` turns on
    /// `waitingHelperWrites`, for a test.
    init(helperSocketPath: String, link: any TerminalStreamLink,
         countsWaitingWrites: Bool = false) throws {
        self.helperSocketPath = helperSocketPath
        self.link = link
        self.countsWaitingWrites = countsWaitingWrites
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

    /// The listening descriptor, or -1 once the helper has been accepted or the bridge
    /// stopped. For tests.
    var listeningDescriptor: Int32 {
        lock.lock(); defer { lock.unlock() }
        return listenFd
    }

    /// How many writes to the helper are waiting for the one in progress, when the
    /// bridge was built with `countsWaitingWrites`; always 0 otherwise. For tests.
    var waitingHelperWrites: Int {
        lock.lock(); defer { lock.unlock() }
        return helperWritersWaiting
    }

    /// The helper's descriptor while it is open. For tests.
    var helperDescriptor: Int32? {
        lock.lock(); defer { lock.unlock() }
        return helperOpen ? helperFd : nil
    }

    /// Claims the grid at this size. Never blocks: the link queues the write.
    ///
    /// Returns whether the claim was accepted: sent to the live link, or kept for the
    /// next one. The owner counts a claim (as one the server will answer) only when this
    /// returns true. It refuses, and returns false for, a `cols` or `rows` outside
    /// `claimRange`, which the hub would ignore without an answer, and any claim after
    /// `stop()`.
    ///
    /// Every claim is answered by the server once, and the owner counts the answers,
    /// so claims are never folded. While no link is live (before the helper connects,
    /// and between a link's end and the next `reconnect`) they are all kept, in order,
    /// up to `maxPendingClaims` (the oldest dropped beyond that, which the owner can
    /// only meet by claiming thousands of times while disconnected), and sent to the
    /// next link that starts. A claim is not sent again to a link `reconnect` starts:
    /// after a reconnect the owner claims again if it still owns the grid.
    @discardableResult
    func claim(cols: Int, rows: Int) -> Bool {
        guard Self.claimRange.contains(cols), Self.claimRange.contains(rows) else { return false }
        control.lock()
        defer { control.unlock() }
        lock.lock()
        let current = link
        let live = !stopped && liveLink == ObjectIdentifier(current)
        if !live, !stopped {
            pendingClaims.append((cols, rows))
            if pendingClaims.count > Self.maxPendingClaims {
                pendingClaims.removeFirst(pendingClaims.count - Self.maxPendingClaims)
            }
        }
        let accepted = !stopped
        lock.unlock()
        if live { current.claim(cols: cols, rows: rows) }
        return accepted
    }

    /// Makes the link again after a lost connection, keeping the helper. Never blocks.
    ///
    /// Meant to be called from `onEnded` only. The old link is stopped on a queue of
    /// the bridge's own, so a callback of it blocked on the helper does not hold this
    /// caller; but that stop waits for the surface to read, and a `reconnect` for any
    /// other reason while a replaced link is stalled that way piles retired links up
    /// on that queue until the surface reads.
    ///
    /// No message of the old link is written to the helper once this has been called,
    /// except a write already in progress, which completes before the new link's first.
    /// A callback of the old link that was already in progress (an `onResize` or an
    /// `onEnded` past its check) may still run once after this returns; nothing of the
    /// old link starts after that.
    ///
    /// A `reconnect` that no `onEnded` preceded must be treated as one by the owner:
    /// it resets its count of unanswered claims (replaces its `GridOwnership`), since
    /// a claim sent to the old link may never be answered. The new link is started at
    /// once if the helper is connected, else when it connects, and is sent the claims
    /// kept while no link was live.
    func reconnect(with newLink: any TerminalStreamLink) {
        lock.lock()
        let old = link
        link = newLink
        liveLink = nil
        let stopOld = stoppedLink != ObjectIdentifier(old)
        stoppedLink = ObjectIdentifier(old)
        lock.unlock()
        if stopOld { retiring.async { old.stop() } }
        control.lock()
        startLinkIfReady()
        control.unlock()
    }

    /// Stops the link, closes the helper's connection and the listener, and removes the
    /// socket file. Idempotent.
    ///
    /// Never waits for the helper: its socket is shut down first, which fails a write
    /// to it that is blocked. It does wait, through the link's `stop()`, for an
    /// `onResize` or `onEnded` that is running, unless called from inside one; which is
    /// why those must never wait on the main thread. It does not wait for a link
    /// `reconnect` replaced, so a callback of such a link already in progress may run
    /// after it returns, and so may `onHelperGone` (see there). Nothing else is called
    /// after it returns.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        helperAlive = false
        liveLink = nil
        pendingClaims = []
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
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if code == EMFILE || code == ENFILE || code == ENOMEM || code == ENOBUFS {
                    pauseAccepting()
                }
                return
            }
            // `accept` does not carry FD_CLOEXEC over: the helper is spawned by
            // libghostty, and a surface spawned later must not inherit this.
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Darwin does carry O_NONBLOCK over, and every read and write here blocks.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            // A write to a socket whose peer has gone raises SIGPIPE, which would
            // kill the app when a helper goes away mid-write (measured as exit
            // status 141 on a one byte write, when the relay owned this socket).
            // Darwin has no MSG_NOSIGNAL, and this is not inherited from the
            // listener.
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

            // The listener has done its one job: closed now, through its source's
            // cancel handler once this handler returns, so a live terminal holds no
            // descriptor for it. The file stays until `stop()`, the one place that
            // unlinks it (checked against the file it bound): a connect to it is
            // refused meanwhile, as a second helper always was.
            lock.lock()
            let source = listenSource
            listenSource = nil
            listenFd = -1
            lock.unlock()
            source?.cancel()

            // The link first, so the helper's first keystrokes find it started.
            control.lock()
            startLinkIfReady()
            control.unlock()
            let thread = Thread { [self] in readHelper(fd) }
            thread.name = "eu.kloosterman.wietty.bridge.helper"
            thread.start()
            return
        }
    }

    /// Stops accepting for `acceptRetryDelay`, as `LocalStreamServer` does: out of
    /// descriptors (or memory) the listener stays readable, and the source would fire
    /// again at once and spin the queue.
    private func pauseAccepting() {
        lock.lock()
        let source = listenSource
        lock.unlock()
        guard let source else { return }
        // On the source's own queue, inside its handler. A source must not be
        // released while suspended, so the resume holds it; a `stop` meanwhile
        // cancels it, and its cancel handler (the close) runs once it is resumed.
        source.suspend()
        queue.asyncAfter(deadline: .now() + Self.acceptRetryDelay) { source.resume() }
    }

    /// The helper's reader thread: its bytes to the link, until it goes away. Bytes
    /// read while no link is live are dropped by the link.
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
    /// write uses it, stops the link, and tells the owner unless it stopped the bridge.
    private func helperGone(_ fd: Int32) {
        lock.lock()
        helperAlive = false
        liveLink = nil
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
        let report = stopped ? nil : helperGoneHandler
        lock.unlock()
        helperWriteLock.unlock()
        if stopLink { current.stop() }
        report?()
    }

    /// Writes `bytes` to the helper in full, blocking until it has taken them, if the
    /// link `id` is still the bridge's. Checked under the write lock, so once
    /// `reconnect` has swapped the link no message of the old one is written, and the
    /// only old write that can follow the swap is one already in progress, which the
    /// new link's first write waits for.
    private func writeToHelper(_ bytes: [UInt8], from id: ObjectIdentifier) {
        if countsWaitingWrites { lock.lock(); helperWritersWaiting += 1; lock.unlock() }
        helperWriteLock.lock()
        if countsWaitingWrites { lock.lock(); helperWritersWaiting -= 1; lock.unlock() }
        defer { helperWriteLock.unlock() }
        lock.lock()
        let fd = helperFd
        let live = helperOpen && !stopped && ObjectIdentifier(link) == id
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

    /// Starts the current link if the helper is there and it has not been started, and
    /// sends it the claims kept meanwhile. Called with `control` held; never blocks.
    private func startLinkIfReady() {
        lock.lock()
        let current = link
        let id = ObjectIdentifier(current)
        guard !stopped, helperAlive, startedLink != id else { lock.unlock(); return }
        startedLink = id
        liveLink = id
        let claims = pendingClaims
        pendingClaims = []
        lock.unlock()

        current.onMessage = { [weak self] message in self?.received(message, from: id) }
        current.onEnded = { [weak self] reason in self?.ended(reason, from: id) }
        current.start()
        for claim in claims { current.claim(cols: claim.cols, rows: claim.rows) }
    }

    /// On the link's thread. Blocks for as long as the helper takes the bytes.
    private func received(_ message: StreamMessage, from id: ObjectIdentifier) {
        switch message {
        case .snapshot(let bytes), .repaint(let bytes), .data(let bytes):
            writeToHelper(bytes, from: id)
        case let .resize(cols, rows, own):
            lock.lock()
            let current = !stopped && ObjectIdentifier(link) == id
            let resize = resizeHandler
            lock.unlock()
            if current { resize?(cols, rows, own) }
        case .hello, .error, .ended:
            break
        }
    }

    private func ended(_ reason: TerminalEndReason, from id: ObjectIdentifier) {
        lock.lock()
        let current = !stopped && ObjectIdentifier(link) == id
        if liveLink == id { liveLink = nil }
        let handler = endHandler
        lock.unlock()
        guard current else { return }
        handler?(reason)
    }
}
