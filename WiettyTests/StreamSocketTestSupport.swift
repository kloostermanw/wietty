import Darwin
import Foundation

/// Shared by `LocalSocketLinkTests` and `TerminalBridgeTests`: bounded waits, a call
/// on a thread of its own, and a plain client socket.

/// Polls `condition` until it holds or `seconds` pass, so a deadlock fails the test
/// instead of hanging the suite.
func waitUntil(within seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

/// A short socket path in the temp directory. `sun_path` is 104 bytes, and the temp
/// directory spends about half.
func shortSocketPath(_ prefix: String) -> String {
    NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString.prefix(8)).sock"
}

/// Runs `body` on a thread of its own and reports when it has returned.
final class BackgroundCall: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    var hasFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    init(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            body()
            lock.lock(); finished = true; lock.unlock()
            done.signal()
        }
        thread.start()
    }

    /// True when the call returned within `seconds`.
    func wait(_ seconds: Double = 5) -> Bool {
        done.wait(timeout: .now() + seconds) == .success
    }
}

/// A plain blocking Unix stream socket, connected, standing in for a peer.
final class UnixTestSocket: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var open = true

    init(connectingTo path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var suppress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    init(accepted fd: Int32) {
        self.fd = fd
        var suppress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard open else { return }
        open = false
        Darwin.close(fd)
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Exactly `count` bytes, or fewer if the socket ends or `seconds` pass first.
    func read(_ count: Int, within seconds: Double = 5) -> [UInt8] {
        readExactly(fd, count, within: seconds)
    }

    /// Whether the peer closed the socket within `seconds`, with nothing more sent.
    func seesEnd(within seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, 50) > 0 else { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            return count <= 0
        }
        return false
    }
}

/// Reads exactly `count` bytes from `fd`, or fewer if it ends or `seconds` pass first.
func readExactly(_ fd: Int32, _ count: Int, within seconds: Double = 5) -> [UInt8] {
    var collected: [UInt8] = []
    let deadline = Date().addingTimeInterval(seconds)
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while collected.count < count {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { break }
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&readable, 1, Int32(max(1, min(remaining, 0.2) * 1000)))
        guard ready > 0 else { continue }
        let wanted = min(buffer.count, count - collected.count)
        let got = Darwin.read(fd, &buffer, wanted)
        if got < 0, errno == EINTR { continue }
        guard got > 0 else { break }
        collected += buffer[0..<got]
    }
    return collected
}

/// Whether `fd` stays silent (nothing readable, no end) for `seconds`.
func staysSilent(_ fd: Int32, for seconds: Double) -> Bool {
    var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&readable, 1, Int32(seconds * 1000)) == 0
}
