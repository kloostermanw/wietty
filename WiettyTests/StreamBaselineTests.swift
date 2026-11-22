import Darwin
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Typing delay and throughput on the terminal byte path, measured from where
/// `wietty-pty` stands: the far end of the route a surface reads and types through.
///
/// A measurement, not a test. It asserts only that the bytes arrived, and prints
/// lines starting with `BASELINE` for a person to compare. It exists so the route
/// can be changed with a number on each side of the change.
///
/// **Everything that knows the route is in `Session` and `openHelperSide(session:)`.**
/// The three measurements see a connected descriptor and nothing else, so the same
/// tests rerun unchanged against a different route by replacing those two.
///
/// **This does not run in the normal suite, by design.** It takes tens of seconds,
/// saturates a core, and its numbers mean nothing beside the rest of a parallel run.
/// It runs only when `WIETTY_STREAM_BASELINE=1` is in the environment, and the one
/// supported way to run it is `scripts/stream-baseline.sh`. Without the variable the
/// suite is reported as skipped.
///
/// Serialized, because two of these running at once would measure each other.
@Suite(.enabled(if: StreamBaseline.isRequested), .serialized)
struct StreamBaselineTests {
    // MARK: The route

    /// One terminal and whatever carries its bytes to the helper side.
    ///
    /// Today that is a `TerminalRelay` on the pty, which is what `GhosttyService`
    /// builds for every terminal, with an output callback that does nothing.
    private final class Session {
        let pty: RawPTY
        let relay: TerminalRelay

        init(command: String) throws {
            pty = try RawPTY.spawn(command: command, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/sh")
            do {
                let path = try TerminalRelay.socketPath(for: "gt:" + UUID().uuidString.lowercased())
                relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
            } catch {
                pty.terminate()
                throw error
            }
            relay.start(onExit: { _ in })
        }

        func close() {
            relay.stop()
            pty.terminate()
        }
    }

    /// A connected descriptor standing where `wietty-pty` stands: what is written to
    /// it is typed into the terminal, and what the terminal prints is read from it.
    private func openHelperSide(session: Session) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BaselineError.connectFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(session.relay.socketPath.utf8)
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
            throw BaselineError.connectFailed(code)
        }
        var suppressSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe,
                   socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    // MARK: The measurements

    /// The tty's own echo, so the child's speed is not part of the number: `cat` in
    /// canonical mode reads nothing until a newline, and the line discipline echoes
    /// each byte as it arrives. Each round sends one `x` and reads until exactly that
    /// byte is back.
    private static let echoCommand = "exec /bin/cat"
    private static let echoRounds = 2_000
    private static let echoPause: useconds_t = 5_000
    /// The canonical queue holds 1,024 bytes (`MAX_CANON`), and a full one rings the
    /// bell instead of echoing. A newline every this many rounds, outside the timed
    /// part, empties it.
    private static let echoRoundsPerLine = 250

    @Test func echoDelay() async throws {
        let samples = try await measureEcho()
        print("BASELINE echo \(Self.summary(samples))")
    }

    /// The same, while the main thread is busy for 50 ms out of every 60. A route
    /// that hops through the main actor shows it here and not above.
    @Test func echoDelayWithBusyMainThread() async throws {
        let busy = Task { @MainActor in
            while !Task.isCancelled {
                let until = DispatchTime.now().uptimeNanoseconds + 50_000_000
                while DispatchTime.now().uptimeNanoseconds < until {}
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { busy.cancel() }
        let samples = try await measureEcho()
        print("BASELINE echo-busy \(Self.summary(samples))")
    }

    private static let throughputBytes = 100_000_000
    /// The payload is the brief's `head | tr`. It waits for one line of input first,
    /// because the route may drop output that arrives before the helper side is
    /// connected (the relay keeps the newest megabyte), and a count of exactly this
    /// many bytes would then never complete. Echo goes off first so the line costs
    /// no output, and one `R` says it has. The clock starts with the line.
    private static let throughputCommand =
        "stty -echo; printf R; read go; head -c \(throughputBytes) /dev/zero | tr '\\0' a"

    @Test func throughput() async throws {
        let session = try Session(command: Self.throughputCommand)
        defer { session.close() }
        let fd = try openHelperSide(session: session)
        defer { Darwin.close(fd) }
        let elapsed = try await Self.offMain {
            // Echo must be off before the line is sent, or the newline is echoed
            // into the count.
            var ready = [UInt8](repeating: 0, count: 1)
            _ = try Self.readSome(fd, into: &ready, timeout: 10)
            guard ready[0] == UInt8(ascii: "R") else { throw BaselineError.unexpectedByte(ready[0]) }
            let start = DispatchTime.now().uptimeNanoseconds
            try Self.writeAll(fd, [UInt8(ascii: "\n")])
            var received = 0
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while received < Self.throughputBytes {
                received += try Self.readSome(fd, into: &buffer, timeout: 10)
            }
            return (DispatchTime.now().uptimeNanoseconds - start, received)
        }
        #expect(elapsed.1 == Self.throughputBytes)
        let seconds = Double(elapsed.0) / 1e9
        let rate = Double(Self.throughputBytes) / 1_048_576 / seconds
        print("BASELINE throughput MiB/s=\(String(format: "%.1f", rate))")
    }

    // MARK: Helpers, ignorant of the route

    private func measureEcho() async throws -> [UInt64] {
        let session = try Session(command: Self.echoCommand)
        defer { session.close() }
        let fd = try openHelperSide(session: session)
        defer { Darwin.close(fd) }
        return try await Self.offMain {
            // One untimed round first: it proves the echo works and absorbs
            // whatever the start of the stream costs. Then a newline, so the timed
            // rounds start on an empty line.
            _ = try Self.echoRound(fd)
            try Self.endLine(fd)
            var samples: [UInt64] = []
            samples.reserveCapacity(Self.echoRounds)
            for round in 1...Self.echoRounds {
                usleep(Self.echoPause)
                samples.append(try Self.echoRound(fd))
                if round % Self.echoRoundsPerLine == 0 { try Self.endLine(fd) }
            }
            return samples
        }
    }

    /// Sends one `x` and reads until exactly that byte comes back, in nanoseconds.
    private static func echoRound(_ fd: Int32) throws -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        try writeAll(fd, [UInt8(ascii: "x")])
        var byte = [UInt8](repeating: 0, count: 1)
        let count = try readSome(fd, into: &byte, timeout: 5)
        let end = DispatchTime.now().uptimeNanoseconds
        guard count == 1, byte[0] == UInt8(ascii: "x") else {
            throw BaselineError.unexpectedByte(byte[0])
        }
        return end - start
    }

    /// Ends the line, and reads until both its echo and `cat`'s copy of it are in,
    /// so the next round starts from a quiet stream.
    private static func endLine(_ fd: Int32) throws {
        try writeAll(fd, [UInt8(ascii: "\n")])
        var newlines = 0
        var byte = [UInt8](repeating: 0, count: 1)
        while newlines < 2 {
            _ = try readSome(fd, into: &byte, timeout: 5)
            if byte[0] == UInt8(ascii: "\n") { newlines += 1 }
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                throw BaselineError.writeFailed(errno)
            }
        }
    }

    /// Reads whatever is there, up to the buffer's size, waiting at most `timeout`
    /// seconds for the first byte.
    private static func readSome(_ fd: Int32, into buffer: inout [UInt8],
                                 timeout: TimeInterval) throws -> Int {
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&readable, 1, Int32(timeout * 1000))
        guard ready > 0 else { throw BaselineError.timedOut }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        guard count > 0 else { throw BaselineError.closed }
        return count
    }

    /// Runs the blocking reads on a thread of their own, so they hold neither the
    /// main thread nor a thread of the cooperative pool.
    private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T)
        async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func summary(_ samples: [UInt64]) -> String {
        let sorted = samples.sorted()
        func ms(_ quantile: Double) -> String {
            let index = min(sorted.count - 1, Int((Double(sorted.count) * quantile).rounded(.down)))
            return String(format: "%.3f", Double(sorted[index]) / 1e6)
        }
        return "median=\(ms(0.5)) p95=\(ms(0.95))"
    }
}

enum StreamBaseline {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_STREAM_BASELINE"] == "1"
    }
}

private enum BaselineError: Error {
    case connectFailed(Int32)
    case writeFailed(Int32)
    case timedOut
    case closed
    case unexpectedByte(UInt8)
}
