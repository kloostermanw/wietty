import Foundation
import Darwin
import WiettyShared

/// Serves the terminal stream on a Unix socket, to the Mac's own panes.
///
/// The same messages as `WS /attach`, in the codec's Unix socket framing (four
/// bytes of big endian length, a type byte, the payload). A client connects, and
/// its first frame must be a `hello` naming protocol 2 and a session; the server
/// answers `hello` and attaches the client to the hub as a *local* viewer
/// (`ScreenStreaming.attachLocal`), which is written to with a blocking write and
/// never dropped. See `docs/remote-access.md`, "The terminal stream".
///
/// ## Threads
///
/// Each connection has a thread of its own that reads it, and that thread is the
/// one that calls `attachLocal`. Nothing writes on a queue of this class: every
/// message is written, whole, on the thread the hub calls `write` from (the pty's
/// read thread, or the hub's delivery queue during the attach and for control
/// messages). The hello and an `error` are written by the reading thread before
/// the attach, when no other writer exists yet.
///
/// `attachLocal` writes the snapshot before it returns, so a client that does not
/// read holds its own reading thread there. That is the only thing it holds of
/// this class: `stop()` and the client's own socket closing both make that write
/// fail, neither needs the reading thread to notice anything, and the attach then
/// returns and the thread ends the connection.
///
/// ## Ending a connection
///
/// Always on the connection's own thread, once, in this order: `shutdown` (which
/// makes a write blocked on the socket fail at once), `detach` (which waits for a
/// `write` in progress, and after which none starts), `close`. The descriptor is
/// therefore never closed while a `write` could still use it, and `stop()` only
/// ever shuts sockets down, under the connection's lock, so it never touches a
/// descriptor that may already be closed and reused, and never waits for a pane.
package final class LocalStreamServer: @unchecked Sendable {
    /// The send buffer of every accepted socket. The hub's delivery queue writes a
    /// `resize`, a claim's answer or an `ended` to an idle viewer itself, and must
    /// not be held by a pane that is momentarily not reading: these have to fit.
    package static let sendBufferSize: Int32 = 256 << 10
    /// The most a viewer may send in one message, as on the WebSocket route.
    package static let maxInboundMessage = 1 << 20

    package let path: String

    private let streamer: any ScreenStreaming
    private let helloTimeout: TimeInterval
    private let peerCheck: @Sendable (Int32) -> Bool
    private let queue = DispatchQueue(label: "eu.kloosterman.wietty.local-stream")

    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    /// Whether a source has been made for `listenFd`. Once it has, only that
    /// source's cancel handler may close the descriptor.
    private var listenSourceStarted = false
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var stopped = false
    /// The socket file as bound, so `stop` unlinks only that file and not one
    /// another server has put at the path since.
    private let boundFile: (device: dev_t, inode: ino_t)

    /// Binds the socket at `path`, replacing a stale file there. Accepts nothing
    /// until `start`.
    ///
    /// `peerCheck` decides whether a connected peer may speak; by default it must be
    /// this process's own user. `helloTimeout` is how long a client may take to send
    /// its `hello` before it is closed with no reply.
    package init(path: String, streamer: any ScreenStreaming,
                 helloTimeout: TimeInterval = 5,
                 peerCheck: @escaping @Sendable (Int32) -> Bool = LocalStreamServer.isSameUser) throws {
        guard path.utf8.count < LocalSocketPaths.sunPathLimit else {
            throw TerminalRelayError.socketPathTooLong(path)
        }
        self.path = path
        self.streamer = streamer
        self.helloTimeout = helloTimeout
        self.peerCheck = peerCheck
        let fd = try Self.listen(at: path)
        var info = stat()
        stat(path, &info)
        boundFile = (info.st_dev, info.st_ino)
        listenFd = fd
    }

    deinit { stop() }

    /// Whether the socket's peer runs as this process's user.
    package static func isSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    /// The listening descriptor, or -1 once stopped. For tests.
    package var listeningDescriptor: Int32 {
        lock.lock(); defer { lock.unlock() }
        return listenFd
    }

    /// The descriptors of the connections not yet closed. For tests.
    package var connectionDescriptors: [Int32] {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        return all.compactMap(\.openDescriptor)
    }

    // MARK: Listening

    /// Binds and listens, with the socket file never reachable by anyone else.
    ///
    /// The mode of a socket file comes from the umask at `bind`, which is process
    /// wide, and `fchmod` does not reach the file of a socket. So the socket is
    /// bound inside a fresh directory of mode 0700 next to `path` (`mkdtemp`), set
    /// to 0600 there, and only then renamed onto `path`, which also replaces a
    /// stale file atomically. While its mode is wider, nobody but this user can
    /// reach it, because nobody else can enter the directory.
    private static func listen(at path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        var template = Array((directory + "/.wty-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw TerminalRelayError.bindFailed(errno) }
        let privateDirectory = String(cString: made)
        defer { rmdir(privateDirectory) }
        let bindPath = privateDirectory + "/s"
        guard bindPath.utf8.count < LocalSocketPaths.sunPathLimit else {
            throw TerminalRelayError.socketPathTooLong(bindPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalRelayError.socketFailed(errno) }
        func fail(_ error: (Int32) -> TerminalRelayError) -> TerminalRelayError {
            let code = errno
            close(fd)
            unlink(bindPath)
            return error(code)
        }
        // macOS has no SOCK_CLOEXEC, so this follows the socket call as closely as
        // it can: a child spawned in between would inherit the listener.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var suppressSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(bindPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw fail(TerminalRelayError.bindFailed) }
        guard chmod(bindPath, 0o600) == 0 else { throw fail(TerminalRelayError.bindFailed) }
        guard rename(bindPath, path) == 0 else { throw fail(TerminalRelayError.bindFailed) }
        // Accepting runs on a dispatch source and must never block on a client
        // that went away between being readable and being accepted.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw TerminalRelayError.listenFailed(code)
        }
        return fd
    }

    /// Starts accepting connections. Does nothing after `stop`, or when started.
    package func start() {
        lock.lock()
        let fd = listenFd
        guard !stopped, fd >= 0, !listenSourceStarted else { lock.unlock(); return }
        // Claimed before the source exists, so a `stop` racing this one cannot
        // decide the descriptor is unwatched and close it itself.
        listenSourceStarted = true
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()

        lock.lock()
        let stale = stopped
        if !stale { listenSource = source }
        lock.unlock()
        if stale { source.cancel() }
    }

    /// The listen source's event handler: the listener cannot be closed while this
    /// runs, because only that source's cancel handler closes it.
    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            prepare(fd)
            // Before a byte is read, and before any thread exists for it.
            guard peerCheck(fd) else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd, streamer: streamer, helloTimeout: helloTimeout)
            lock.lock()
            let refused = stopped
            if !refused { connections[ObjectIdentifier(connection)] = connection }
            lock.unlock()
            guard !refused else { close(fd); continue }
            let thread = Thread { [weak self] in
                connection.serve()
                self?.forget(connection)
            }
            thread.name = "eu.kloosterman.wietty.local-stream.connection"
            thread.start()
        }
    }

    /// What an accepted socket does not inherit from the listener, or must not.
    private func prepare(_ fd: Int32) {
        // `accept` does not carry FD_CLOEXEC over.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Darwin does carry O_NONBLOCK over, and every read and write here blocks.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        // Without this, a pane that goes away mid-write kills the app: see
        // `TerminalRelay.accept`. Not inherited from the listener.
        var suppressSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var size = Self.sendBufferSize
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    private func forget(_ connection: Connection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    /// Stops accepting, ends every connection, and removes the socket file.
    /// Idempotent. Waits for nothing: each connection is shut down here and ended
    /// by its own thread.
    package func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let listen = listenFd
        listenFd = -1
        let source = listenSource
        listenSource = nil
        let watched = listenSourceStarted
        let all = Array(connections.values)
        lock.unlock()

        for connection in all { connection.shutDown() }
        if let source {
            source.cancel()
        } else if !watched, listen >= 0 {
            close(listen)
        }
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == boundFile.device, info.st_ino == boundFile.inode {
            unlink(path)
        }
    }
}

/// One client of the server, from its peer check to its close.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let streamer: any ScreenStreaming
    private let helloTimeout: TimeInterval

    private let lock = NSLock()
    /// Whether `fd` is still this connection's. Cleared only by `close`, under the
    /// lock, so a `shutDown` from another thread never reaches a reused number.
    private var open = true
    /// A write failed or `ended` was written: nothing more is written, and the
    /// connection ends.
    private var finished = false

    init(fd: Int32, streamer: any ScreenStreaming, helloTimeout: TimeInterval) {
        self.fd = fd
        self.streamer = streamer
        self.helloTimeout = helloTimeout
    }

    var openDescriptor: Int32? {
        lock.lock(); defer { lock.unlock() }
        return open ? fd : nil
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Makes a blocked write fail and the reader see the end. Safe from any thread.
    func shutDown() {
        lock.lock()
        if open { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        finished = true
        if open { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    private func close() {
        lock.lock()
        if open {
            open = false
            Darwin.close(fd)
        }
        lock.unlock()
    }

    // MARK: Serving

    /// Runs on the connection's own thread, and ends the connection before it returns.
    func serve() {
        var viewer: UUID?
        defer {
            // The one order that never closes a descriptor a write still uses.
            shutDown()
            if let viewer { streamer.detach(connectionId: viewer) }
            close()
        }

        var reader = StreamFrameReader(maxPayload: LocalStreamServer.maxInboundMessage)
        guard let (first, rest) = readHello(&reader) else { return }
        guard case let .hello(version, session, resize) = first else {
            return refuse("hello", "the first message must be hello")
        }
        guard version == StreamProtocol.version else {
            return refuse("protocol", "this server speaks protocol \(StreamProtocol.version)")
        }
        guard let session, !session.isEmpty else {
            return refuse("session", "the hello names no session")
        }

        write(.hello(protocolVersion: StreamProtocol.version, session: nil, resize: nil))
        guard !isFinished else { return }
        // Blocks until the grid and the snapshot are written. A client that does not
        // read them is released by its own close or by `stop`, both of which make
        // that write fail without this thread.
        viewer = streamer.attachLocal(session: session, resize: resize ?? .reflow) { [self] message in
            write(message)
        }
        guard let id = viewer, !isFinished else { return }
        handle(rest, session: session, viewer: id)
        guard reader.failure == nil else { return }

        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            let messages: [StreamMessage]
            do {
                messages = try reader.append(Array(buffer[0..<count]))
            } catch {
                return
            }
            handle(messages, session: session, viewer: id)
            // A refused frame after good ones in the same read: those went through,
            // and the connection ends with no reply.
            guard reader.failure == nil else { return }
        }
    }

    /// Waits up to `helloTimeout` for the first message. Nil when nothing usable
    /// came: the client was silent, went away, or sent a frame the reader refused,
    /// in which case it has been answered with an `error`.
    private func readHello(_ reader: inout StreamFrameReader)
        -> (StreamMessage, [StreamMessage])? {
        let deadline = Date().addingTimeInterval(helloTimeout)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readable, 1, Int32(max(1, min(remaining * 1000, 1000))))
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { return nil }
            guard ready > 0 else { continue }
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            let messages: [StreamMessage]
            do {
                messages = try reader.append(Array(buffer[0..<count]))
            } catch {
                refuse("hello", "the first frame is not a message")
                return nil
            }
            if let first = messages.first { return (first, Array(messages.dropFirst())) }
            if reader.failure != nil {
                refuse("hello", "the first frame is not a message")
                return nil
            }
        }
    }

    private func refuse(_ code: String, _ text: String) {
        write(.error(code: code, message: text))
        finish()
    }

    private func handle(_ messages: [StreamMessage], session: String, viewer: UUID) {
        for message in messages {
            switch message {
            case .data(let bytes): streamer.send(session: session, bytes: bytes)
            case let .resize(cols, rows, _): streamer.claim(connectionId: viewer, cols: cols, rows: rows)
            default: break
            }
        }
    }

    // MARK: Writing

    /// One message, as one frame, written in full on the calling thread. Never
    /// called concurrently: before the attach only the reading thread writes, and
    /// after it only the hub, which never overlaps its calls. The descriptor is
    /// open for the call, because it is closed only after `detach` has returned.
    private func write(_ message: StreamMessage) {
        guard !isFinished else { return }
        guard let frame = try? StreamCodec.checkedSocketFrame(for: message),
              writeAll(frame) else {
            return finish()
        }
        if case .ended = message { finish() }
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                // An interrupted write has copied nothing and is not a failure.
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
