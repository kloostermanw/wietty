import Foundation
import Darwin

enum TerminalRelayError: Error, Equatable {
    case socketPathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Relays one terminal's bytes between the PTY Wietty owns and the libghostty
/// surface that renders it.
///
/// libghostty spawns and owns its own child and offers neither a byte feed nor an
/// output callback, so the surface runs `wietty-pty`, which connects here and
/// does nothing but copy. This is the Wietty end of that socket.
///
/// Output is written twice on the one read: to `onOutput`, which reaches
/// `PaneStreamHub` and every remote viewer, and to the helper, which reaches the
/// surface. Both happen on the pty's single read source, in order, because
/// terminal output delivered out of order is corrupt on screen.
///
/// Window size deliberately does not travel on this socket. Wietty reads the
/// surface geometry from libghostty directly and resizes the pty itself, which
/// keeps this a plain byte pipe with no framing and keeps the helper free of
/// signal handling.
///
/// ## Descriptor lifetime
///
/// Two descriptors outlive a single call here (the listener and the accepted
/// helper), and `stop` can arrive from the UI while a read or a write is in
/// flight on either. Descriptors are recycled, so closing one out from under a
/// syscall does not fail, it writes a screenful of terminal output into whatever
/// this process opened next. Three rules keep that impossible:
///
/// 1. Every close of a descriptor a `DispatchSource` watches happens in that
///    source's cancel handler. Dispatch runs a cancel handler only after the last
///    event handler has returned, so `accept` and the helper's `read`, which are
///    those handlers, can never overlap the close of the fd they name.
/// 2. Writes to the helper run on the pty's read queue, not on this class's
///    queue, so they *can* overlap a cancel. They go through `withClient`, which
///    counts uses; a cancel handler arriving mid-write defers the close to
///    whichever call finishes last. This is the same reference counting `RawPTY`
///    applies to the pty master, and for the same reason.
/// 3. The client fd is published to `clientFd` only once a source is guaranteed
///    to be created for it, and cleared before that source is cancelled, so no
///    use can start against a descriptor already on its way out.
final class TerminalRelay: @unchecked Sendable {
    /// How much output to hold for a helper that has not connected yet.
    ///
    /// A surface is created after the shell is spawned, so anything printed in
    /// that window (a prompt, a shell startup notice) would otherwise never reach
    /// the local view even though remote viewers already have it. Bounded,
    /// because a terminal whose surface never appears would grow this without
    /// limit; the oldest bytes are dropped, since the newest screen is the one
    /// worth showing.
    private static let preConnectLimit = 1 << 20

    /// `sockaddr_un.sun_path` is this many bytes, terminator included.
    private static let sunPathLimit = 104

    let socketPath: String

    private let pty: RawPTY
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let queue = DispatchQueue(label: "eu.kloosterman.wietty.relay")

    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    /// Whether a source has been made for `listenFd`. Once it has, only that
    /// source's cancel handler may close the descriptor.
    private var listenSourceStarted = false
    private var clientFd: Int32 = -1
    private var clientSource: DispatchSourceRead?
    /// Writes currently using `clientFd`, and the descriptor a cancel handler
    /// asked to close while one was running.
    private var clientInFlight = 0
    private var clientDeferredClose: Int32 = -1
    private var pending: [UInt8] = []
    /// Whether the pre-connect backlog is still being flushed. New output queues
    /// behind it rather than overtaking it.
    private var draining = false
    private var stopped = false

    /// The socket path for a session id.
    ///
    /// Short on purpose. `sockaddr_un.sun_path` is 104 bytes including the
    /// terminator, and the per user temp directory already spends roughly half of
    /// that, so the name gets a fixed prefix and a truncated id rather than the
    /// session id in full. Collisions are not a concern: the id is a UUID and 12
    /// hex digits of one are unique across the terminals a single launch holds.
    ///
    /// The directory is a parameter so the budget can be tested. It is also the
    /// only part that can overflow it, the id being truncated: `TMPDIR` is
    /// inherited from whatever launched the app, and a path that does not fit has
    /// to fail loudly rather than bind a silently truncated one, which would leave
    /// the helper connecting to a socket nobody listens on.
    static func socketPath(for sessionId: String,
                           in directory: String = NSTemporaryDirectory()) throws -> String {
        let compact = sessionId
            .replacingOccurrences(of: "gt:", with: "")
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
        let path = directory + "ipx-\(compact).sock"
        guard path.utf8.count < Self.sunPathLimit else {
            throw TerminalRelayError.socketPathTooLong(path)
        }
        return path
    }

    init(pty: RawPTY, socketPath: String,
         onOutput: @escaping @Sendable ([UInt8]) -> Void) throws {
        guard socketPath.utf8.count < Self.sunPathLimit else {
            throw TerminalRelayError.socketPathTooLong(socketPath)
        }
        self.pty = pty
        self.socketPath = socketPath
        self.onOutput = onOutput
        self.listenFd = try Self.listen(at: socketPath)
    }

    deinit { stop() }

    private static func listen(at path: String) throws -> Int32 {
        // A file left by a crashed run would fail the bind, and the path is
        // derived from the session id, so it does recur.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalRelayError.socketFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw TerminalRelayError.bindFailed(code)
        }
        // Backlog of one: exactly one helper ever connects, because exactly one
        // surface renders this terminal.
        guard Darwin.listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            throw TerminalRelayError.listenFailed(code)
        }
        return fd
    }

    func start(onExit: @escaping @Sendable (Int32) -> Void) {
        acceptHelper()
        pty.startReading(onBytes: { [weak self] bytes in
            guard let self else { return }
            // The remote path first, and unconditionally: a viewer must not be
            // held up by, or lost to, a helper that has not connected.
            self.onOutput(bytes)
            self.sendToHelper(bytes)
        }, onExit: onExit)
    }

    private func acceptHelper() {
        lock.lock()
        let fd = listenFd
        guard !stopped, fd >= 0 else { lock.unlock(); return }
        // Claimed before the source exists, so a `stop` racing this one cannot
        // decide the descriptor is unwatched and close it itself.
        listenSourceStarted = true
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        source.resume()

        lock.lock()
        let stale = stopped
        if !stale { listenSource = source }
        lock.unlock()
        // `stop` ran while this was being installed, and left the cancel to here
        // because it had no source to cancel.
        if stale { source.cancel() }
    }

    private func accept() {
        lock.lock()
        let fd = listenFd
        lock.unlock()
        // Safe to use outside the lock: this is the listen source's event
        // handler, and the only close of `listenFd` is that source's cancel
        // handler, which dispatch will not run until this returns.
        guard fd >= 0 else { return }
        let accepted = Darwin.accept(fd, nil, nil)
        guard accepted >= 0 else { return }

        lock.lock()
        // A second connection means something other than this terminal's own
        // helper reached the socket. There is nothing useful to do with it, and
        // splicing it in would interleave two input streams into one shell.
        let reject = stopped || clientFd >= 0
        if !reject {
            clientFd = accepted
            draining = true
        }
        lock.unlock()
        guard !reject else { close(accepted); return }

        // Without this, the app dies when the helper does. A write to a socket
        // whose peer has gone raises SIGPIPE, whose default disposition is to
        // terminate the process, and nothing in Wietty handles it: measured as
        // exit status 141 on a one byte write. The helper is a child of the
        // libghostty surface, so it goes away whenever a terminal is closed, and
        // taking the whole app down with it is not a theoretical risk. Darwin has
        // no MSG_NOSIGNAL, and an accepted socket does not inherit this from the
        // listener, so it is set here, per connection. The write then simply fails
        // with EPIPE, which the writer already reads as "the helper is gone".
        var suppressSigpipe: Int32 = 1
        setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(accepted, &buffer, buffer.count)
            guard count > 0 else {
                // The helper is gone, which means the surface is gone. There is
                // nothing to reconnect to: the helper exists only as the
                // surface's child.
                self?.closeClient()
                return
            }
            self?.pty.write(Array(buffer[0..<count]))
        }
        source.setCancelHandler { [weak self] in
            // Without self there can be no write in flight, because every write
            // goes through it, so the descriptor can go straight away.
            if let self { self.releaseClient(accepted) } else { close(accepted) }
        }
        source.resume()

        lock.lock()
        let stale = clientFd != accepted
        if !stale { clientSource = source }
        lock.unlock()
        // `closeClient` ran while this was being installed and found no source to
        // cancel, so the close is finished here.
        guard !stale else { source.cancel(); return }

        drainPending()
    }

    /// Flushes everything buffered before the helper connected, and keeps
    /// flushing until nothing is left.
    ///
    /// The drain runs outside the lock, because a write to a helper that has
    /// stopped reading blocks, and holding the lock across it would stall the pty
    /// read source on `sendToHelper`. So output produced during the drain has to
    /// keep queueing rather than take the direct path and land ahead of the
    /// backlog: `draining` is what holds that ordering, and it is only cleared
    /// with the queue observed empty under the same lock.
    private func drainPending() {
        while true {
            lock.lock()
            guard !stopped, clientFd >= 0 else {
                pending = []
                draining = false
                lock.unlock()
                return
            }
            let chunk = pending
            pending = []
            if chunk.isEmpty {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            withClient { write($0, chunk) }
        }
    }

    private func sendToHelper(_ bytes: [UInt8]) {
        lock.lock()
        // Nothing to hold it for once stopped: the surface this fed is gone.
        guard !stopped else { lock.unlock(); return }
        if clientFd < 0 || draining {
            pending.append(contentsOf: bytes)
            if pending.count > Self.preConnectLimit {
                pending.removeFirst(pending.count - Self.preConnectLimit)
            }
            lock.unlock()
            return
        }
        lock.unlock()
        withClient { write($0, bytes) }
    }

    /// Runs `body` with the helper's descriptor, or does nothing when there is no
    /// helper. The descriptor cannot be closed for the duration, even by a cancel
    /// handler that arrives mid-write.
    private func withClient(_ body: (Int32) -> Void) {
        lock.lock()
        let fd = clientFd
        // `stopped` is deliberately not consulted: `stop` retires the client by
        // clearing `clientFd`, so that is the one condition, and `closeClient`
        // itself has to be able to reach the descriptor after `stopped` is set.
        guard fd >= 0 else { lock.unlock(); return }
        clientInFlight += 1
        lock.unlock()
        defer { finishUsingClient() }
        body(fd)
    }

    /// Drops one use, and performs a close that was deferred while it was running.
    private func finishUsingClient() {
        lock.lock()
        clientInFlight -= 1
        let fd = clientDeferredClose
        let closeNow = fd >= 0 && clientInFlight == 0
        if closeNow { clientDeferredClose = -1 }
        lock.unlock()
        if closeNow { close(fd) }
    }

    /// Closes the helper's descriptor, or hands it to the last write still using
    /// it. Only the client source's cancel handler reaches here, so this runs at
    /// most once per accepted connection.
    private func releaseClient(_ fd: Int32) {
        lock.lock()
        let closeNow = clientInFlight == 0
        if !closeNow { clientDeferredClose = fd }
        lock.unlock()
        if closeNow { close(fd) }
    }

    /// Retires the current helper. The descriptor itself is closed by the source's
    /// cancel handler, never here, because dispatch must be done with it first.
    private func closeClient() {
        // A helper that stopped reading parks the write, and with it the pty's
        // read source, until the peer goes away. Cancelling the source would not
        // release it and closing the descriptor is not allowed while a write holds
        // it, so the socket is shut down instead: the parked write returns EPIPE
        // at once and the thread is given back. Done through `withClient`, and
        // before the source is cancelled, so the descriptor cannot have been
        // closed and recycled underneath it.
        withClient { shutdown($0, SHUT_RDWR) }

        lock.lock()
        clientFd = -1
        draining = false
        pending = []
        let source = clientSource
        clientSource = nil
        lock.unlock()
        // A nil source means `accept` is still installing one; it sees the
        // cleared `clientFd` and cancels it itself.
        source?.cancel()
    }

    /// Tears the relay down and removes the socket file. Idempotent.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let listen = listenFd
        listenFd = -1
        let listenSrc = listenSource
        listenSource = nil
        let listenWatched = listenSourceStarted
        lock.unlock()

        closeClient()
        if let listenSrc {
            listenSrc.cancel()
        } else if !listenWatched, listen >= 0 {
            // No source was ever made for it, so nothing else will close it.
            close(listen)
        }
        unlink(socketPath)
    }

    /// Writes every byte, or stops at the first failure.
    private func write(_ fd: Int32, _ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                // An interrupted write has copied nothing and is not a failure;
                // abandoning the buffer here would punch a hole in the stream.
                if written < 0, errno == EINTR { continue }
                // Anything else means the helper is gone. Dropping the rest is
                // correct: the surface it fed no longer exists.
                return
            }
        }
    }
}
