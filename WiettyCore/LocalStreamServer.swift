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
/// read thread, this connection's own thread for the attach, or the hub's delivery
/// queue for control messages). The hello and an `error` are written by the
/// reading thread before the attach, when no other writer exists yet.
///
/// `attachLocal` writes the snapshot on this connection's thread before it
/// returns, so a client that does not read holds its own reading thread there, and
/// its own terminal's output, which waits for the snapshot; never the hub's
/// delivery queue. `stop()`, the client's own socket closing and the write deadline
/// below each make that write fail, none needs the reading thread to notice
/// anything, and the attach then returns and the thread ends the connection.
///
/// ## The write deadline
///
/// Every message other than `data` is written with a progress deadline
/// (`controlWriteDeadline`, 5 seconds): the connection is ended if the client reads
/// nothing for that long while such a message is being written. What restarts the
/// deadline is the client reading, which makes room in the socket, so a client that
/// reads slowly but steadily keeps its connection however long a snapshot takes.
/// The rule bounds a client that has stopped, not one that reads very slowly, and
/// it bounds each stopped one separately. The hub writes control messages to an
/// idle viewer on its delivery queue, which every remote viewer of every terminal
/// shares, and a pane that stopped reading would otherwise park it until `stop()`.
/// The snapshot is written on this connection's thread instead, and there the
/// deadline bounds how long a stopped pane holds its own terminal. A frame cut off
/// by the deadline is never completed: the socket is closed, so the client sees a
/// lost connection, not a corrupt stream.
///
/// `data` is written with no deadline, blocking for as long as the client does not
/// read: that wait is the backpressure that lets a slow pane hold back the child,
/// and it runs on the pty's thread. The rule is by message kind, not by thread. The
/// hub never writes `data` to a local viewer from its delivery queue: that `data`
/// is made only in `PaneStreamHub.write(session:bytes:)` on the pty's thread, and
/// what the queue leaves pending for a busy viewer is control messages only. The
/// pty's thread does write control messages, though: what was left pending for the
/// viewer, ahead of its chunk, and those keep the deadline of their kind.
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
    /// The most connections served at once by default. Every live local terminal's
    /// pane holds one for as long as the terminal lives, so this is a limit on live
    /// terminals, and it is set far above what a person opens. One more is answered
    /// `error` with code `busy` (see `serveBusy`), so its client ends as refused rather
    /// than as a lost connection it would try again.
    package static let maxConnections = 1024
    /// How long accepting pauses when the process is out of descriptors or memory.
    static let acceptRetryDelay: DispatchTimeInterval = .milliseconds(100)

    package let path: String

    private let streamer: any ScreenStreaming
    private let helloTimeout: TimeInterval
    private let controlWriteDeadline: TimeInterval
    private let connectionLimit: Int
    private let peerCheck: @Sendable (Int32) -> Bool
    private let acceptCall: @Sendable (Int32) -> Int32
    private let sendTimeoutCall: @Sendable (Int32, TimeInterval) -> Int32
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
    private let boundFile: PrivateSocket.Identity

    /// Binds the socket at `path`, replacing a stale file there. Accepts nothing
    /// until `start`.
    ///
    /// `path` must be absolute. `peerCheck` decides whether a connected peer may
    /// speak; by default it must be this process's own user. `helloTimeout` is how
    /// long a client may take, counted from the accept, to send a whole `hello`
    /// before it is closed with no reply. `controlWriteDeadline` is the write
    /// deadline above. `maxConnections` is the cap (`LocalStreamServer.maxConnections`
    /// unless a test lowers it). `accept` stands in for `accept(2)` in tests: it returns the
    /// descriptor, or -1 with `errno` set. `setSendTimeout` stands in for setting a
    /// socket's `SO_SNDTIMEO` in tests: it returns what `setsockopt` would.
    package init(path: String, streamer: any ScreenStreaming,
                 helloTimeout: TimeInterval = 5,
                 controlWriteDeadline: TimeInterval = 5,
                 maxConnections: Int = LocalStreamServer.maxConnections,
                 peerCheck: @escaping @Sendable (Int32) -> Bool = LocalStreamServer.isSameUser,
                 accept: @escaping @Sendable (Int32) -> Int32 = { Darwin.accept($0, nil, nil) },
                 setSendTimeout: @escaping @Sendable (Int32, TimeInterval) -> Int32
                     = LocalStreamServer.setSendTimeout) throws {
        self.path = path
        self.streamer = streamer
        self.helloTimeout = helloTimeout
        self.controlWriteDeadline = controlWriteDeadline
        self.connectionLimit = maxConnections
        self.peerCheck = peerCheck
        self.acceptCall = accept
        self.sendTimeoutCall = setSendTimeout
        // A backlog as deep as the cap: panes restored at launch connect at once.
        // The kernel caps it (`kern.ipc.somaxconn`); asking for more is harmless.
        let (fd, identity) = try PrivateSocket.listen(at: path, backlog: Int32(min(maxConnections, 1024)))
        boundFile = identity
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

    /// Sets the socket's `SO_SNDTIMEO`, 0 for none, and returns `setsockopt`'s result.
    package static func setSendTimeout(_ fd: Int32, _ seconds: TimeInterval) -> Int32 {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1e6))
        return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Runs `body` with the listening descriptor while it cannot be closed, or
    /// returns nil once stopped. For tests.
    package func withListeningDescriptor<T>(_ body: (Int32) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        // The listener is closed only after `stop` has cleared `listenFd` under this lock.
        return listenFd >= 0 ? body(listenFd) : nil
    }

    /// Runs `body` with the descriptor of each connection not yet closed, while it
    /// cannot be closed. For tests.
    package func inspectConnections<T>(_ body: (Int32) -> T) -> [T] {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        return all.compactMap { $0.withOpenDescriptor(body) }
    }

    /// The connections the cap counts: one is added at its accept and removed once
    /// its thread has ended it, a moment after its descriptor is closed. For tests.
    package var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    // MARK: Listening

    // The socket is bound by `PrivateSocket.listen`, which keeps its file out of
    // reach of anyone else from the moment it exists.

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
            let fd = acceptCall(listener)
            if fd < 0 {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if code == EMFILE || code == ENFILE || code == ENOMEM || code == ENOBUFS {
                    pauseAccepting()
                }
                return
            }
            prepare(fd)
            // Before a byte is read, and before any thread exists for it.
            guard peerCheck(fd) else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd, streamer: streamer, helloTimeout: helloTimeout,
                                        controlWriteDeadline: controlWriteDeadline,
                                        setSendTimeout: sendTimeoutCall)
            lock.lock()
            let isStopped = stopped
            let full = !isStopped && connections.count >= connectionLimit
            if !isStopped, !full { connections[ObjectIdentifier(connection)] = connection }
            lock.unlock()
            guard !isStopped else { close(fd); continue }
            // Over the cap: answered `busy` on a thread of its own, uncounted, which
            // ends within the hello timeout at the latest. Never on this queue, which
            // must not wait for a client.
            let thread = Thread { [weak self] in
                if full {
                    connection.serveBusy()
                } else {
                    connection.serve()
                    self?.forget(connection)
                }
            }
            thread.name = "eu.kloosterman.wietty.local-stream.connection"
            thread.start()
        }
    }

    /// Stops accepting for `acceptRetryDelay`. Out of descriptors (or memory), the
    /// listener stays readable, and the source would fire again at once and spin the
    /// queue until one is freed. The clients waiting meanwhile stay in the backlog
    /// and are accepted once there is room. Chosen over keeping a spare descriptor to
    /// close and accept with: that holds a descriptor for good and still has to
    /// close the client it accepts, while a pause serves it a moment later.
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

    /// What an accepted socket does not inherit from the listener, or must not.
    private func prepare(_ fd: Int32) {
        // `accept` does not carry FD_CLOEXEC over.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Darwin does carry O_NONBLOCK over, and every read and write here blocks.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        // Without this, a pane that goes away mid-write kills the app: the write
        // raises SIGPIPE, whose default is to terminate, and Darwin has no
        // MSG_NOSIGNAL. Not inherited from the listener.
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
    /// by its own thread, which may therefore still call `send`, `claim` or `detach`
    /// on the streamer after this has returned (its `detach` always comes last).
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
        PrivateSocket.unlink(path, ifStill: boundFile)
    }
}

/// One client of the server, from its peer check to its close.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let streamer: any ScreenStreaming
    private let helloTimeout: TimeInterval
    private let controlWriteDeadline: TimeInterval
    private let sendTimeoutCall: @Sendable (Int32, TimeInterval) -> Int32

    private let lock = NSLock()
    /// Whether `fd` is still this connection's. Cleared only by `close`, under the
    /// lock, so a `shutDown` from another thread never reaches a reused number.
    private var open = true
    /// A write failed or `ended` was written: nothing more is written, and the
    /// connection ends.
    private var finished = false
    /// The `SO_SNDTIMEO` set on the socket, 0 for none.
    private var sendTimeout: TimeInterval = 0

    init(fd: Int32, streamer: any ScreenStreaming, helloTimeout: TimeInterval,
         controlWriteDeadline: TimeInterval,
         setSendTimeout: @escaping @Sendable (Int32, TimeInterval) -> Int32) {
        self.fd = fd
        self.streamer = streamer
        self.helloTimeout = helloTimeout
        self.controlWriteDeadline = controlWriteDeadline
        self.sendTimeoutCall = setSendTimeout
    }

    /// `body` with the descriptor, under the lock that keeps it open; nil once closed.
    func withOpenDescriptor<T>(_ body: (Int32) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        return open ? body(fd) : nil
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

    /// Refuses a connection over the cap: waits for its first message (so the client's
    /// `hello` has been taken and nothing it writes fails before it reads the answer),
    /// answers `error` with code `busy` whatever that message was, and ends the
    /// connection. A client that sends nothing is closed at the hello timeout with no
    /// reply. Not counted against the cap, and not shut down by `stop()`; it ends on
    /// its own within the hello timeout.
    func serveBusy() {
        defer {
            shutDown()
            close()
        }
        var reader = StreamFrameReader(maxPayload: LocalStreamServer.maxInboundMessage)
        guard readHello(&reader) != nil else { return }
        refuse("busy", "this Wietty serves as many panes as it can")
    }

    /// Waits up to `helloTimeout`, counted from the accept, for the first message.
    /// Nil when nothing usable came: the client was silent, trickled bytes or sent
    /// half a frame until the time was up, sent only frames the codec skips, went
    /// away, or sent a frame the reader refused, in which case it has been answered
    /// with an `error`.
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

    /// One message, as one frame, written in full on the calling thread, or the
    /// connection ends. Never called concurrently: before the attach only the reading
    /// thread writes, and after it only the hub, which never overlaps its calls. The
    /// descriptor is open for the call, because it is closed only after `detach` has
    /// returned. `data` blocks for as long as it takes; anything else is held to the
    /// write deadline (see `LocalStreamServer`).
    private func write(_ message: StreamMessage) {
        guard !isFinished else { return }
        guard let frame = try? StreamCodec.checkedSocketFrame(for: message) else { return finish() }
        let written: Bool
        if case .data = message {
            written = writeAll(frame)
        } else {
            written = writeAll(frame, progressDeadline: controlWriteDeadline)
        }
        guard written else { return finish() }
        if case .ended = message { finish() }
    }

    /// Writes every byte, or gives up once the socket has accepted nothing for
    /// `progressDeadline` seconds. False then, or on a failure.
    ///
    /// The deadline is the socket's `SO_SNDTIMEO`, which bounds each wait for room
    /// inside one `write`: a call that copied nothing in that time fails with
    /// `EAGAIN`, and one that copied part of the frame and then waited that long
    /// returns short. A short return that came sooner was a signal, and the write
    /// goes on. Measured on macOS: neither `MSG_DONTWAIT` nor `poll` then `send`
    /// works here, because `send` with `MSG_DONTWAIT` of a frame larger than the free
    /// room blocks on a Unix socket regardless; and `O_NONBLOCK` is shared with the
    /// connection's blocking reads.
    private func writeAll(_ bytes: [UInt8], progressDeadline: TimeInterval) -> Bool {
        setSendTimeout(max(progressDeadline, 0.001))
        let allowed = UInt64(max(progressDeadline, 0.001) * 1e9)
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let started = DispatchTime.now().uptimeNanoseconds
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    // EAGAIN: no byte accepted for the whole deadline.
                    return false
                }
                guard written > 0 else { return false }
                offset += written
                if offset < raw.count, DispatchTime.now().uptimeNanoseconds - started >= allowed { return false }
            }
            return true
        }
    }

    /// The socket's send timeout, changed only when it differs from what is set.
    /// Only the one writer of the moment calls this. The value is recorded only once
    /// `setsockopt` has taken it, so one that failed is tried again on the next write
    /// rather than believed in force.
    private func setSendTimeout(_ seconds: TimeInterval) {
        lock.lock()
        let current = sendTimeout
        lock.unlock()
        guard current != seconds else { return }
        guard sendTimeoutCall(fd, seconds) == 0 else { return }
        lock.lock()
        sendTimeout = seconds
        lock.unlock()
    }

    private func writeAll(_ bytes: [UInt8]) -> Bool {
        // No timeout: `data` waits for as long as the client does not read.
        setSendTimeout(0)
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
