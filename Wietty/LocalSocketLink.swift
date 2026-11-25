import Darwin
import Foundation
import WiettyCore
import WiettyShared

/// A terminal's stream from this Mac's own `LocalStreamServer`, on its Unix socket.
///
/// No call on it waits for the server: `start`, `send` and `claim` return at once,
/// whatever the server is doing. Only `stop()` waits, and only for a callback that is
/// running (see `stop()`).
///
/// ## Threads
///
/// Each `start()` makes two threads. The reader connects, then reads the socket,
/// decodes frames with a `StreamFrameReader` that allows a message up to
/// `StreamProtocol.maxMessageSize` (a snapshot is one message), and calls `onMessage`
/// for each, in order. It reads again only when the callback has returned: a callback
/// that blocks (the bridge writing to a surface that is not reading) leaves the next
/// frame on the socket, the socket fills, and the server's blocking write on the pty's
/// thread waits. What this link holds meanwhile is the frames one `read` of 64 KiB
/// happened to carry and at most one partial frame.
///
/// The writer writes the outbox, in order, with blocking writes. The first frame in it
/// is `hello(protocol: 2, session:, resize: .reflow)`, put there by `start()`, so it
/// precedes every `send` and `claim`. `send` and `claim` only append to the outbox:
/// one `resize` frame for a claim, and for input one `data` frame per 64 KiB (the
/// server refuses an inbound frame over 1 MiB), appended together so another call's
/// frames never land between them. The outbox is not bounded: it holds input the
/// server has not read yet, which is what was typed or pasted, and claims. A failed
/// write ends the link as `.connectionLost` through the reader.
///
/// ## Ends
///
/// The first frame must be a version 2 `hello`, which is consumed. After it: `ended`
/// ends the link as `.sessionEnded`, `error` as `.refused`, a closed socket or a frame
/// the reader refuses as `.connectionLost` (since the server's fix round, a pane whose
/// control write stalls for 5 seconds is disconnected, which arrives here as this). A
/// first frame that is not `hello` ends it as `.serverTooOld`, a newer `hello` as
/// `.refused(code: "protocol")`, as the package's `TerminalStreamConnection` treats
/// them. A failed connect ends it as `.connectionLost`. `onEnded` runs on the reader
/// thread, once. After an end, `send` and `claim` are dropped.
///
/// ## Descriptor lifetime
///
/// The socket is closed only by the reader thread, as it exits, after the writer has
/// exited. Everything else (an end, `stop()`, a failed write) only shuts it down,
/// under the lock and while it is open, which releases a blocked `read` or `write` at
/// once and never touches a number already closed and reused.
final class LocalSocketLink: TerminalStreamLink, @unchecked Sendable {
    private enum Phase {
        case idle, awaitingHello, streaming, ended, stopped

        var isLive: Bool { self == .awaitingHello || self == .streaming }
    }

    /// The largest `data` frame `send` writes. The server takes up to 1 MiB.
    static let maxInputFrame = 64 << 10

    let path: String
    let session: String

    /// Guards everything below, and wakes the writer.
    private let lock = NSCondition()
    private var phase: Phase = .idle
    private var fd: Int32 = -1
    /// Whether `fd` is still this link's. Cleared only by the reader thread's close.
    private var open = false
    private var outbox: [[UInt8]] = []
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var reader: Thread?

    /// Held for each callback; `stop()` takes it to wait for one in progress.
    private let callbackLock = NSLock()

    init(path: String, session: String) {
        self.path = path
        self.session = session
    }

    /// Called on the link's reader thread. See the protocol for what it may do.
    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return messageHandler }
        set { lock.lock(); messageHandler = newValue; lock.unlock() }
    }

    /// Called on the link's reader thread, once.
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return endHandler }
        set { lock.lock(); endHandler = newValue; lock.unlock() }
    }

    /// Queues the hello and starts the threads that connect, write and read. Returns at
    /// once. Does nothing when started already or stopped.
    func start() {
        guard let hello = try? StreamCodec.checkedSocketFrame(
            for: .hello(protocolVersion: StreamProtocol.version, session: session, resize: .reflow))
        else { return }
        lock.lock()
        guard phase == .idle else { lock.unlock(); return }
        phase = .awaitingHello
        outbox = [hello]
        let thread = Thread { [self] in run() }
        thread.name = "eu.kloosterman.wietty.local-link.reader"
        reader = thread
        lock.unlock()
        thread.start()
    }

    /// Closes the connection. Fires no `onEnded`. Idempotent.
    ///
    /// Waits for a callback that is running, so that after it returns none runs and
    /// none comes; called from inside a callback it cannot wait for that one, returns
    /// at once, and nothing comes after it either. It waits for nothing else: not for
    /// the server, not for the socket to close (the reader thread closes it a moment
    /// later).
    func stop() {
        lock.lock()
        phase = .stopped
        outbox = []
        if open { shutdown(fd, SHUT_RDWR) }
        lock.broadcast()
        let readerThread = reader
        lock.unlock()
        guard Thread.current !== readerThread else { return }
        callbackLock.lock()
        callbackLock.unlock()
    }

    /// Input, byte exact. Never blocks: queued for the writer, in frames of at most
    /// `maxInputFrame` bytes. Dropped before `start()` and after an end or a stop.
    func send(_ bytes: [UInt8]) {
        var frames: [[UInt8]] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.maxInputFrame, bytes.count)
            frames.append(StreamCodec.socketFrame(for: .data(Array(bytes[start..<end]))))
            start = end
        }
        enqueue(frames)
    }

    /// Claims the grid at this size; `own` is sent as false. Never blocks, as `send`.
    func claim(cols: Int, rows: Int) {
        enqueue([StreamCodec.socketFrame(for: .resize(cols: cols, rows: rows, own: false))])
    }

    private func enqueue(_ frames: [[UInt8]]) {
        guard !frames.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard phase.isLive else { return }
        outbox += frames
        lock.signal()
    }

    // MARK: The reader thread

    /// Connects, runs the writer, reads until the end, and closes the socket.
    private func run() {
        let socket = Self.connect(to: path)
        lock.lock()
        guard phase.isLive else {
            lock.unlock()
            if socket >= 0 { close(socket) }
            return
        }
        guard socket >= 0 else {
            lock.unlock()
            return end(.connectionLost)
        }
        fd = socket
        open = true
        lock.unlock()

        let writerDone = DispatchSemaphore(value: 0)
        let writer = Thread { [self] in
            write(socket)
            writerDone.signal()
        }
        writer.name = "eu.kloosterman.wietty.local-link.writer"
        writer.start()

        read(socket)
        // `read` returns only once the link has ended or stopped, both of which shut
        // the socket down and wake the writer, so this wait is short.
        writerDone.wait()
        lock.lock()
        open = false
        fd = -1
        lock.unlock()
        close(socket)
    }

    private func read(_ socket: Int32) {
        var frames = StreamFrameReader(maxPayload: StreamProtocol.maxMessageSize)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = Darwin.read(socket, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return end(.connectionLost) }
            let messages: [StreamMessage]
            do {
                messages = try frames.append(Array(buffer[0..<count]))
            } catch {
                return end(.connectionLost)
            }
            for message in messages {
                guard process(message) else { return }
            }
            guard frames.failure == nil else { return end(.connectionLost) }
        }
    }

    /// Handles one message. False once the link is over and nothing more is read.
    private func process(_ message: StreamMessage) -> Bool {
        lock.lock()
        let current = phase
        lock.unlock()
        switch (current, message) {
        case (.ended, _), (.stopped, _), (.idle, _):
            return false
        case (.awaitingHello, .hello(let version, _, _)) where version == StreamProtocol.version:
            lock.lock()
            if phase == .awaitingHello { phase = .streaming }
            lock.unlock()
            return true
        case (.awaitingHello, .hello(let version, _, _)) where version > StreamProtocol.version:
            end(.refused(code: "protocol",
                         message: "The terminal is served by a newer Wietty."))
            return false
        case (_, .error(let code, let text)):
            end(.refused(code: code, message: text))
            return false
        case (.awaitingHello, _):
            end(.serverTooOld)
            return false
        case (_, .ended):
            end(.sessionEnded)
            return false
        case (_, .hello):
            return true
        case (.streaming, _):
            deliver(message)
            return true
        }
    }

    /// Calls `onMessage`, under the callback lock, unless the link is over. Checked
    /// under that lock, so a `stop()` either waits for this callback or prevents it.
    private func deliver(_ message: StreamMessage) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        lock.lock()
        let live = phase == .streaming
        let handler = messageHandler
        lock.unlock()
        guard live else { return }
        handler?(message)
    }

    /// Ends the link for `reason`, once, unless it was stopped.
    private func end(_ reason: TerminalEndReason) {
        lock.lock()
        guard phase.isLive else { lock.unlock(); return }
        phase = .ended
        outbox = []
        if open { shutdown(fd, SHUT_RDWR) }
        lock.broadcast()
        lock.unlock()
        // As `deliver`: a `stop()` from now on either waits for this or prevents it.
        callbackLock.lock()
        defer { callbackLock.unlock() }
        lock.lock()
        let live = phase == .ended
        let handler = endHandler
        lock.unlock()
        guard live else { return }
        handler?(reason)
    }

    // MARK: The writer thread

    /// Writes the outbox until the link is over or a write fails. The socket is open
    /// throughout: the reader closes it only after this has returned.
    private func write(_ socket: Int32) {
        while true {
            lock.lock()
            while outbox.isEmpty && phase.isLive { lock.wait() }
            guard phase.isLive else { lock.unlock(); return }
            let frame = outbox.removeFirst()
            lock.unlock()
            guard Self.writeAll(socket, frame) else {
                // The reader sees the end of the socket and ends the link.
                lock.lock()
                if open { shutdown(socket, SHUT_RDWR) }
                lock.unlock()
                return
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
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

    // MARK: Connecting

    /// A connected socket, or -1.
    private static func connect(to path: String) -> Int32 {
        let bytes = Array(path.utf8)
        guard bytes.count < LocalSocketPaths.sunPathLimit else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        // macOS has no SOCK_CLOEXEC: as close to the socket call as it can be.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Without this, a server that goes away mid-write kills the app.
        var suppressSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }
}
