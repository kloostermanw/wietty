import Darwin
import Foundation
import WiettyCore
import WiettyShared

/// A terminal's stream from this Mac's own `LocalStreamServer`, on its Unix socket.
///
/// `start()` connects and writes `hello(protocol: 2, session:, resize: .reflow)` on
/// the calling thread, before any other frame, then hands the socket to a reader
/// thread of the link's own. A failed connect ends the link on that thread too, as
/// `.connectionLost`.
///
/// ## The reader thread
///
/// One per `start()`. It reads the socket, decodes frames with a `StreamFrameReader`
/// that allows a message up to `StreamProtocol.maxMessageSize` (a snapshot is one
/// message), and calls `onMessage` for each, in order. It reads again only when the
/// callback has returned: a callback that blocks (the bridge writing to a surface that
/// is not reading) leaves the next frame on the socket, the socket fills, and the
/// server's blocking write on the pty's thread waits. Nothing is buffered here beyond
/// the frames that one `read` happened to carry.
///
/// The first frame must be a version 2 `hello`, which is consumed. After it:
/// `ended` ends the link as `.sessionEnded`, `error` as `.refused`, a closed socket or
/// a frame the reader refuses as `.connectionLost`. A first frame that is not `hello`
/// ends it as `.serverTooOld`, a newer `hello` as `.refused(code: "protocol")`, as the
/// package's `TerminalStreamConnection` treats them.
///
/// ## Writing
///
/// `send` and `claim` write one frame each, whole, with a blocking write on the
/// calling thread, under a lock of their own so two calls' frames never interleave.
/// The server reads its socket promptly, so this blocks only for as long as the
/// server's reading thread is busy; when it is held (it writes the snapshot during the
/// attach before it reads), a write larger than the socket's buffer waits for it. A
/// failed write ends the link as `.connectionLost` through the reader. `send` splits
/// nothing: an input larger than the server's `maxInboundMessage` would make the
/// server drop the connection, so it is dropped here instead. The helper reads at most
/// a few kilobytes at a time, so that does not happen in practice.
///
/// ## Descriptor lifetime
///
/// The socket is closed only by the reader thread, as it exits, and only once
/// it holds the write lock, so it is never closed under a `read` or a `write`.
/// Everything else (an end, `stop()`, a failed write) only shuts it down, under
/// the state lock and while it is still open, which releases a blocked `read` or
/// `write` at once and never touches a number already closed and reused.
final class LocalSocketLink: TerminalStreamLink, @unchecked Sendable {
    private enum Phase {
        case idle, awaitingHello, streaming, ended, stopped
    }

    let path: String
    let session: String

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var fd: Int32 = -1
    /// Whether `fd` is still this link's. Cleared only by the reader thread's close.
    private var open = false
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var reader: Thread?

    /// Held for each frame written, so frames never interleave; the close takes it to
    /// wait for a write in progress.
    private let writeLock = NSLock()
    /// Held for each callback; `stop()` takes it to wait for one in progress.
    private let callbackLock = NSLock()

    init(path: String, session: String) {
        self.path = path
        self.session = session
    }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return messageHandler }
        set { lock.lock(); messageHandler = newValue; lock.unlock() }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return endHandler }
        set { lock.lock(); endHandler = newValue; lock.unlock() }
    }

    /// Connects, says hello, and starts reading. Does nothing when started already
    /// or stopped.
    func start() {
        lock.lock()
        guard phase == .idle else { lock.unlock(); return }
        phase = .awaitingHello
        lock.unlock()

        let connected = Self.connect(to: path)
        // The hello goes out before any `send` or `claim` can: they wait on the write
        // lock, and they find the socket only once it is published under it.
        writeLock.lock()
        lock.lock()
        let live = phase == .awaitingHello
        if live, connected >= 0 {
            fd = connected
            open = true
        }
        lock.unlock()
        guard live else {
            writeLock.unlock()
            if connected >= 0 { close(connected) }
            return
        }
        if connected >= 0 {
            let hello = StreamMessage.hello(protocolVersion: StreamProtocol.version,
                                            session: session, resize: .reflow)
            if let frame = try? StreamCodec.checkedSocketFrame(for: hello),
               !Self.writeAll(connected, frame) {
                shutDown()
            }
        }
        writeLock.unlock()

        let thread = Thread { [self] in read(connected) }
        thread.name = "eu.kloosterman.wietty.local-link"
        lock.lock()
        reader = thread
        lock.unlock()
        thread.start()
    }

    /// Closes the connection. Fires no `onEnded`. Idempotent. See the type's protocol
    /// for what it waits for.
    func stop() {
        lock.lock()
        phase = .stopped
        if open { shutdown(fd, SHUT_RDWR) }
        let readerThread = reader
        lock.unlock()
        // Waits for a callback in progress. From inside one it would wait for itself.
        guard Thread.current !== readerThread else { return }
        callbackLock.lock()
        callbackLock.unlock()
    }

    func send(_ bytes: [UInt8]) {
        write(.data(bytes))
    }

    /// Claims the grid at this size. `own` means nothing upstream and is sent as false.
    func claim(cols: Int, rows: Int) {
        write(.resize(cols: cols, rows: rows, own: false))
    }

    // MARK: Writing

    private func write(_ message: StreamMessage) {
        guard let frame = try? StreamCodec.checkedSocketFrame(
            for: message, maxPayload: LocalStreamServer.maxInboundMessage) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let live = (phase == .awaitingHello || phase == .streaming) && open
        let socket = fd
        lock.unlock()
        guard live else { return }
        // Open for the whole write: only the reader closes it, and only under the
        // write lock. A failure is seen by the reader as the end of the socket.
        if !Self.writeAll(socket, frame) { shutDown() }
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

    // MARK: Reading

    /// The reader thread's body. Ends the link (unless stopped) and closes the socket
    /// before it returns.
    private func read(_ socket: Int32) {
        defer { closeSocket() }
        guard socket >= 0 else { return end(.connectionLost) }
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
        guard phase == .awaitingHello || phase == .streaming else { lock.unlock(); return }
        phase = .ended
        if open { shutdown(fd, SHUT_RDWR) }
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

    /// Makes a blocked read or write fail. Safe from any thread.
    private func shutDown() {
        lock.lock()
        if open { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    /// Only the reader thread, as it exits. By then the socket is shut down, so a
    /// write in progress fails and lets go of the write lock.
    private func closeSocket() {
        writeLock.lock()
        lock.lock()
        if open {
            open = false
            close(fd)
            fd = -1
        }
        lock.unlock()
        writeLock.unlock()
    }

    // MARK: Connecting

    /// A connected socket, or -1.
    private static func connect(to path: String) -> Int32 {
        let bytes = Array(path.utf8)
        guard bytes.count < 104 else { return -1 }
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
