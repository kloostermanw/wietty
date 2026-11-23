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
/// The measurements see a connected descriptor and nothing else, so the same
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
    /// Today that is a `TerminalRelay` on the pty, wired the way `GhosttyService.open`
    /// and `GhosttyStack` wire every terminal: the relay's output callback runs the
    /// `ProgramStatusTap`, then `PaneStreamHub.write`, whose `onIngest` feeds the
    /// session's libghostty-vt screen model under the session's lock, and only then
    /// does the relay write the chunk to the helper. That work sits on the same read
    /// source as the helper's bytes, so a baseline without it would be faster than
    /// the app. No viewer is attached to the hub; its flush timer runs, as the app's
    /// does.
    private final class Session {
        let pty: RawPTY
        let relay: TerminalRelay
        let hub: PaneStreamHub

        init(command: String) throws {
            let session = "gt:" + UUID().uuidString.lowercased()
            // `GhosttyService.initialSize`, and the default scrollback limit.
            let size = TerminalSize(cols: 120, rows: 34)
            let model = try GhosttyVtScreenModel(size: size,
                                                 scrollbackLines: TerminalScrollback.defaultLines,
                                                 graphemeClustering: true)
            let shared = SharedTerminalState()
            let hub = PaneStreamHub(startTimer: true)
            // Every hook `GhosttyStack` sets, set the same way. With no viewer only
            // `onIngest` runs, but a hook left out here would be a difference from
            // the app that nobody remembers when a viewer is added to this test.
            hub.onIngest = { session, bytes in shared.model(for: session)?.write(bytes) }
            hub.onSnapshot = { session in GhosttyStack.snapshot(of: session, in: shared) }
            hub.onRepaint = { session in shared.model(for: session)?.repaintFrame() }
            hub.onAlternateScreen = { session in shared.model(for: session)?.isAlternateScreen ?? false }
            hub.onInput = { session, bytes in GhosttyStack.input(bytes, for: session, in: shared) }
            self.hub = hub
            let pty: RawPTY
            do {
                pty = try RawPTY.spawn(command: command, directory: URL(fileURLWithPath: "/tmp"),
                                       environment: [:], size: size, shell: "/bin/sh")
            } catch {
                hub.stop()
                throw error
            }
            self.pty = pty
            let status = ProgramStatusTap(reply: { [weak pty] answer in pty?.write(answer) },
                                          report: { _ in })
            do {
                let path = try TerminalRelay.socketPath(for: session)
                relay = try TerminalRelay(pty: pty, socketPath: path) { bytes in
                    status.ingest(bytes)
                    hub.write(session: session, bytes: bytes)
                }
            } catch {
                pty.terminate()
                hub.stop()
                throw error
            }
            shared.note(model: model, for: session)
            shared.register(writer: { [weak pty] bytes in pty?.write(bytes) }, for: session)
            relay.start(onExit: { _ in })
        }

        func close() {
            relay.stop()
            pty.terminate()
            hub.stop()
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
    /// each byte as it arrives. Each round sends one letter and reads exactly that
    /// letter back.
    ///
    /// The letters cycle `a` to `z`, and every round first checks that nothing is
    /// waiting to be read. Both are there because one echo arriving after the pause
    /// would otherwise be read by the next round as its own, in microseconds, and
    /// every sample after it would be shifted with no error.
    private static let echoCommand = "exec /bin/cat"
    /// The pause is well past the hub's 8 ms quiet interval, as a person's typing is,
    /// so every round's echo finds a quiet session and measures the flush after quiet.
    /// At 5 ms each echo was flushed by a timer tick less than one round before the
    /// next, and the rounds after the first measured the timer instead. 750 rounds of
    /// 20 ms keep a run at about 15 s, a multiple of `echoRoundsPerLine`.
    private static let echoRounds = 750
    private static let echoPause: useconds_t = 20_000
    /// The canonical queue holds 1,024 bytes (`MAX_CANON`), and a full one rings the
    /// bell instead of echoing. A newline every this many rounds, outside the timed
    /// part, empties it.
    fileprivate static let echoRoundsPerLine = 250

    @Test func echoDelay() async throws {
        let samples = try await measureEcho()
        print("BASELINE echo \(Self.summary(samples))")
    }

    /// The same, while the main thread is busy for 50 ms out of every 60. A route
    /// that hops through the main actor shows it here and not above.
    ///
    /// The busy loop reports how long it really spun, and the test fails when that
    /// is under half of what 50 out of 60 implies, because an idle main thread would
    /// make this a second copy of the quiet measurement under another name.
    @Test func echoDelayWithBusyMainThread() async throws {
        let busy = Task { @MainActor () -> (spun: UInt64, elapsed: UInt64) in
            let start = DispatchTime.now().uptimeNanoseconds
            var spun: UInt64 = 0
            while !Task.isCancelled {
                let from = DispatchTime.now().uptimeNanoseconds
                let until = from + 50_000_000
                var now = from
                while now < until { now = DispatchTime.now().uptimeNanoseconds }
                spun += now - from
                try? await Task.sleep(for: .milliseconds(10))
            }
            return (spun, DispatchTime.now().uptimeNanoseconds - start)
        }
        let samples: [UInt64]
        do {
            samples = try await measureEcho()
        } catch {
            busy.cancel()
            _ = await busy.value
            throw error
        }
        busy.cancel()
        let load = await busy.value
        let share = Double(load.spun) / Double(max(load.elapsed, 1))
        #expect(share >= 0.5 * 50 / 60,
                "the main thread was busy for \(Int(share * 100)) % of the run, not about 83 %")
        print("BASELINE echo-busy \(Self.summary(samples)) busy=\(Int((share * 100).rounded()))%")
    }

    private static let throughputBytes = 100_000_000
    /// Every throughput command waits for one line of input first, because the
    /// route may drop output that arrives before the helper side is connected (the
    /// relay keeps the newest megabyte). Echo goes off first so the line costs no
    /// output, and one `R` says it has. The clock starts with the line.
    private static let handshake = "stty -echo; printf R; read go; "

    /// One endless line: 100,000,000 bytes of `a` with no newline, so the screen
    /// model wraps it every row for the whole run.
    ///
    /// Written to a file before the session starts, and only `cat` runs inside the
    /// clock, because a generator in the pipeline is itself the limit: `tr` alone
    /// manages about 28 MiB/s. The file is this test's to remove, whatever happens.
    @Test func throughputOneLine() async throws {
        let file = TestScratch.root
            .appendingPathComponent("wietty-baseline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: UInt8(ascii: "a"), count: Self.throughputBytes).write(to: file)
        try await measureThroughput(name: "throughput-oneline",
                                    command: Self.handshake + "cat '\(file.path)'",
                                    payload: Self.throughputBytes, lines: 0)
    }

    /// Ordinary output: 100,000,000 bytes of 80 character lines, 79 characters and a
    /// newline each, so 1,250,000 lines.
    @Test func throughputLines() async throws {
        let line = String(repeating: "abcdefghij", count: 8).prefix(79)
        try await measureThroughput(name: "throughput-lines",
                                    command: Self.handshake + "yes \(line) | head -c \(Self.throughputBytes)",
                                    payload: Self.throughputBytes, lines: Self.throughputBytes / 80)
    }

    // MARK: Helpers, ignorant of the route

    /// Printed after the payload, and found in neither payload.
    private static let endMark = UInt8(ascii: "Z")

    /// Reads the whole stream into memory inside the clock and checks it after.
    ///
    /// The tty turns every newline into CR LF, and when the reader is slower than the
    /// child it writes some as CR CR LF instead: measured as 1,476 of the 1,250,000
    /// lines with the hub in the path, and none with the relay alone. So the byte
    /// count is not fixed. What is fixed is the payload: the bytes that arrived,
    /// less every carriage return, must be exactly `payload`, and there must be
    /// exactly `lines` line feeds. A truncated stream fails either check.
    private func measureThroughput(name: String, command: String,
                                   payload: Int, lines: Int) async throws {
        // The child stays alive after the mark, so the end of the stream is never a
        // race with the terminal closing.
        let session = try Session(command: command
                                  + "; printf \(String(UnicodeScalar(Self.endMark))); exec sleep 120")
        defer { session.close() }
        let fd = try openHelperSide(session: session)
        defer { Darwin.close(fd) }
        let mark = Int32(Self.endMark)
        let capacity = payload + 2 * lines + (1 << 20)
        let result = try await Self.offMain { () -> (nanoseconds: UInt64, bytes: Int, crs: Int, lfs: Int) in
            // Echo must be off before the line is sent, or the newline is echoed
            // into the count.
            var ready = [UInt8](repeating: 0, count: 1)
            _ = try Self.readSome(fd, into: &ready, timeout: 30)
            guard ready[0] == UInt8(ascii: "R") else { throw BaselineError.unexpectedByte(ready[0]) }
            let stream = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            defer { stream.deallocate() }
            // Every page touched now, so no first touch page fault lands in the clock.
            memset(stream, 0, capacity)
            var go = [UInt8(ascii: "\n")]
            var received = 0
            let start = DispatchTime.now().uptimeNanoseconds
            try Self.writeAll(fd, &go)
            while true {
                guard received < capacity else { throw BaselineError.streamTooLong(received) }
                let count = try Self.readSome(fd, into: stream + received,
                                              count: capacity - received, timeout: 10)
                let ended = memchr(stream + received, mark, count) != nil
                received += count
                if ended { break }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            // Outside the clock from here.
            guard received > 0 else { throw BaselineError.emptyStream }
            let last = stream.load(fromByteOffset: received - 1, as: UInt8.self)
            guard last == Self.endMark else { throw BaselineError.unexpectedByte(last) }
            let payloadEnd = received - 1
            return (end - start, payloadEnd,
                    Self.count(13, in: stream, length: payloadEnd),
                    Self.count(10, in: stream, length: payloadEnd))
        }
        #expect(result.lfs == lines, "expected \(lines) lines, \(result.lfs) arrived")
        #expect(result.crs >= lines, "\(result.crs) carriage returns for \(lines) lines")
        #expect(result.bytes - result.crs == payload,
                "expected \(payload) payload bytes, \(result.bytes - result.crs) arrived")
        let seconds = Double(result.nanoseconds) / 1e9
        let rate = Double(result.bytes) / 1_048_576 / seconds
        print("BASELINE \(name) MiB/s=\(String(format: "%.1f", rate))")
    }

    private func measureEcho() async throws -> [UInt64] {
        let session = try Session(command: Self.echoCommand)
        defer { session.close() }
        let fd = try openHelperSide(session: session)
        defer { Darwin.close(fd) }
        return try await Self.offMain {
            var echo = Echo(fd: fd)
            // One untimed round first: it proves the echo works and absorbs
            // whatever the start of the stream costs. Then a newline, so the timed
            // rounds start on an empty line.
            _ = try echo.round()
            try echo.endLine()
            var samples: [UInt64] = []
            samples.reserveCapacity(Self.echoRounds)
            for round in 1...Self.echoRounds {
                usleep(Self.echoPause)
                samples.append(try echo.round())
                if round % Self.echoRoundsPerLine == 0 { try echo.endLine() }
            }
            return samples
        }
    }

    /// How many times `byte` occurs in the first `length` bytes at `start`.
    private static func count(_ byte: UInt8, in start: UnsafeRawPointer, length: Int) -> Int {
        var found = 0
        var cursor = start
        let end = start + length
        while cursor < end, let hit = memchr(cursor, Int32(byte), end - cursor) {
            found += 1
            cursor = UnsafeRawPointer(hit) + 1
        }
        return found
    }

    /// One echo session's state: the next letter, and the line `cat` holds.
    ///
    /// Needs only a descriptor, so `EchoShiftDetectionTests` drives it over a socket
    /// pair with no terminal at all.
    fileprivate struct Echo {
        let fd: Int32
        /// How long to wait for a reply. Short in the tests that expect none.
        let timeout: TimeInterval
        private var next = UInt8(ascii: "a")
        private var line: [UInt8] = []
        private var out = [UInt8](repeating: 0, count: 1)
        private var back = [UInt8](repeating: 0, count: 1)
        private var buffer = [UInt8](repeating: 0, count: 4096)

        init(fd: Int32, timeout: TimeInterval = 5) {
            self.fd = fd
            self.timeout = timeout
            line.reserveCapacity(StreamBaselineTests.echoRoundsPerLine + 1)
        }

        /// Sends the next letter and reads exactly that letter back, in nanoseconds.
        /// The clock covers the write, the wait and the read, nothing else.
        mutating func round() throws -> UInt64 {
            let letter = next
            next = letter == UInt8(ascii: "z") ? UInt8(ascii: "a") : letter + 1
            out[0] = letter
            try StreamBaselineTests.requireQuiet(fd)
            let start = DispatchTime.now().uptimeNanoseconds
            try StreamBaselineTests.writeAll(fd, &out)
            let count: Int
            do {
                count = try StreamBaselineTests.readSome(fd, into: &back, timeout: timeout)
            } catch BaselineError.timedOut {
                throw BaselineError.samplesInvalid(
                    "no echo of \(Character(UnicodeScalar(letter))) within \(timeout) s")
            }
            let end = DispatchTime.now().uptimeNanoseconds
            guard count == 1, back[0] == letter else {
                throw BaselineError.samplesInvalid(
                    "sent \(Character(UnicodeScalar(letter))), read \(back[0]) back")
            }
            line.append(letter)
            return end - start
        }

        /// Ends the line, and reads back exactly its echo (CR LF) and `cat`'s copy
        /// of the letters it held, so the next round starts from a quiet stream.
        ///
        /// Exactly: a reply one byte short times out, and one byte long is caught
        /// either in the same read or by waiting `straggler` for anything after it.
        /// Outside the clock, so the wait costs no sample anything.
        mutating func endLine() throws {
            var newline = [UInt8(ascii: "\n")]
            try StreamBaselineTests.requireQuiet(fd)
            try StreamBaselineTests.writeAll(fd, &newline)
            let expected = [13, 10] + line + [13, 10]
            var got: [UInt8] = []
            while got.count < expected.count {
                let count: Int
                do {
                    count = try StreamBaselineTests.readSome(fd, into: &buffer, timeout: timeout)
                } catch BaselineError.timedOut {
                    throw BaselineError.samplesInvalid("""
                        the line came back short: \(got.count) of \(expected.count) bytes \
                        within \(timeout) s
                        """)
                }
                got += buffer[0..<count]
            }
            var straggler = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if got.count == expected.count, poll(&straggler, 1, Self.stragglerMilliseconds) > 0 {
                let count = try StreamBaselineTests.readSome(fd, into: &buffer, timeout: 0)
                got += buffer[0..<count]
            }
            guard got == expected else {
                throw BaselineError.samplesInvalid("""
                    the line came back as \(got.count) bytes, not \(expected.count), \
                    or not as the letters sent
                    """)
            }
            line.removeAll(keepingCapacity: true)
        }

        private static let stragglerMilliseconds: Int32 = 20
    }

    /// Throws when anything is waiting to be read, which means an echo arrived late
    /// and the rounds can no longer be told apart. A hang up or an error on the
    /// descriptor is reported as what it is.
    fileprivate static func requireQuiet(_ fd: Int32) throws {
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&readable, 1, 0) > 0 else { return }
        let events = Int32(readable.revents)
        if events & POLLIN != 0 {
            throw BaselineError.samplesInvalid("bytes were waiting before a write")
        }
        if events & POLLHUP != 0 {
            throw BaselineError.samplesInvalid("the other side hung up")
        }
        throw BaselineError.samplesInvalid("the descriptor reported an error (revents \(events))")
    }

    fileprivate static func writeAll(_ fd: Int32, _ bytes: inout [UInt8]) throws {
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
    fileprivate static func readSome(_ fd: Int32, into buffer: inout [UInt8],
                                 timeout: TimeInterval) throws -> Int {
        try buffer.withUnsafeMutableBytes {
            try readSome(fd, into: $0.baseAddress!, count: $0.count, timeout: timeout)
        }
    }

    fileprivate static func readSome(_ fd: Int32, into pointer: UnsafeMutableRawPointer, count: Int,
                                 timeout: TimeInterval) throws -> Int {
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&readable, 1, Int32(timeout * 1000))
        guard ready > 0 else { throw BaselineError.timedOut }
        let read = Darwin.read(fd, pointer, count)
        guard read > 0 else { throw BaselineError.closed }
        return read
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

    /// Nearest rank percentiles: the value at index ceil(q * n) - 1 of the sorted
    /// samples, so every reported number is one that was measured.
    private static func summary(_ samples: [UInt64]) -> String {
        let sorted = samples.sorted()
        func ms(_ quantile: Double) -> String {
            let rank = Int((quantile * Double(sorted.count)).rounded(.up))
            let index = min(max(rank - 1, 0), sorted.count - 1)
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

fileprivate enum BaselineError: Error {
    case connectFailed(Int32)
    case writeFailed(Int32)
    case timedOut
    case closed
    case unexpectedByte(UInt8)
    case streamTooLong(Int)
    case emptyStream
    /// An echo arrived out of step, so the samples taken are not measurements of
    /// the rounds they are recorded against.
    case samplesInvalid(String)
}

/// The baseline's guard against shifted samples, proven without a terminal.
///
/// `StreamBaselineTests.Echo` needs only a descriptor, so here it talks over a
/// socket pair to a peer this suite plays, which can answer correctly or wrongly
/// on purpose. Not behind the baseline's gate: these run in the normal suite, in
/// milliseconds, so a change that blinds the detection fails every run.
@Suite struct EchoShiftDetectionTests {
    /// The far end of the socket pair, answering on a thread of its own the way the
    /// tty and `cat` would, through a reply rule a test chooses.
    ///
    /// The rule gets each byte the harness sent and the letters the line holds
    /// before it, and returns what to send back.
    private final class Peer: @unchecked Sendable {
        let harnessFd: Int32
        private let peerFd: Int32
        private let done = DispatchSemaphore(value: 0)

        init(reply: @escaping @Sendable (_ byte: UInt8, _ held: [UInt8]) -> [UInt8]) throws {
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw BaselineError.connectFailed(errno)
            }
            harnessFd = fds[0]
            peerFd = fds[1]
            let fd = peerFd
            let done = self.done
            Thread.detachNewThread {
                var held: [UInt8] = []
                var byte: UInt8 = 0
                while Darwin.read(fd, &byte, 1) == 1 {
                    var answer = reply(byte, held)
                    if byte == UInt8(ascii: "\n") { held = [] } else { held.append(byte) }
                    if !answer.isEmpty { try? StreamBaselineTests.writeAll(fd, &answer) }
                }
                Darwin.close(fd)
                done.signal()
            }
        }

        /// Sends bytes from the peer's side without being asked.
        func push(_ bytes: [UInt8]) throws {
            var bytes = bytes
            try StreamBaselineTests.writeAll(peerFd, &bytes)
        }

        /// Closes the harness's end, which ends the peer's read loop; the peer
        /// closes its own end, so no descriptor is closed under a running read.
        func close() {
            Darwin.close(harnessFd)
            done.wait()
        }
    }

    /// What the tty and `cat` do: echo a letter, and answer a newline with CR LF
    /// and then the line.
    private static func correct(_ byte: UInt8, _ held: [UInt8]) -> [UInt8] {
        byte == UInt8(ascii: "\n") ? [13, 10] + held + [13, 10] : [byte]
    }

    private static func isSamplesInvalid(_ error: any Error) -> Bool {
        if case BaselineError.samplesInvalid = error { return true }
        return false
    }

    @Test func aByteAlreadyWaitingBeforeARoundInvalidatesIt() throws {
        let peer = try Peer(reply: Self.correct)
        defer { peer.close() }
        try peer.push([UInt8(ascii: "q")])
        usleep(10_000)
        var echo = StreamBaselineTests.Echo(fd: peer.harnessFd, timeout: 0.2)
        #expect(performing: { _ = try echo.round() }, throws: Self.isSamplesInvalid)
    }

    /// A late echo: the second round is answered with the first round's letter.
    @Test func anEchoOfThePreviousLetterInvalidatesTheRound() throws {
        let peer = try Peer { byte, held in
            byte == UInt8(ascii: "a") ? [byte] : [held.last ?? 0]
        }
        defer { peer.close() }
        var echo = StreamBaselineTests.Echo(fd: peer.harnessFd, timeout: 0.2)
        _ = try echo.round()
        #expect(performing: { _ = try echo.round() }, throws: Self.isSamplesInvalid)
    }

    /// Two bytes for one: the first round reads its own letter, and the extra byte
    /// is waiting when the next round starts.
    @Test func anEchoOfTwoBytesInvalidatesTheNextRound() throws {
        let peer = try Peer { byte, _ in [byte, byte] }
        defer { peer.close() }
        var echo = StreamBaselineTests.Echo(fd: peer.harnessFd, timeout: 0.2)
        _ = try echo.round()
        #expect(performing: { _ = try echo.round() }, throws: Self.isSamplesInvalid)
    }

    @Test func aFlushReplyOneByteLongInvalidatesTheLine() throws {
        let peer = try Peer { byte, held in
            byte == UInt8(ascii: "\n") ? [13, 10] + held + [13, 10, UInt8(ascii: "!")] : [byte]
        }
        defer { peer.close() }
        var echo = StreamBaselineTests.Echo(fd: peer.harnessFd, timeout: 0.2)
        for _ in 0..<3 { _ = try echo.round() }
        #expect(performing: { try echo.endLine() }, throws: Self.isSamplesInvalid)
    }

    /// One byte short: the line never completes, which is reported as a short line
    /// once the wait runs out.
    @Test func aFlushReplyOneByteShortInvalidatesTheLine() throws {
        let peer = try Peer { byte, held in
            byte == UInt8(ascii: "\n") ? [13, 10] + held.dropLast() + [13, 10] : [byte]
        }
        defer { peer.close() }
        var echo = StreamBaselineTests.Echo(fd: peer.harnessFd, timeout: 0.2)
        for _ in 0..<3 { _ = try echo.round() }
        #expect(performing: { try echo.endLine() }, throws: { error in
            guard case BaselineError.samplesInvalid(let message) = error else { return false }
            return message.contains("short")
        })
    }

    /// A full cycle of the alphabet and more, with a flush in the middle and one at
    /// the end, and every round returns a duration.
    @Test func aCorrectPeerPassesAFullCycleAndFlushes() throws {
        let peer = try Peer(reply: Self.correct)
        defer { peer.close() }
        var echo = StreamBaselineTests.Echo(fd: peer.harnessFd, timeout: 1)
        for round in 1...30 {
            let duration = try echo.round()
            #expect(duration > 0)
            if round == 20 { try echo.endLine() }
        }
        try echo.endLine()
        try StreamBaselineTests.requireQuiet(peer.harnessFd)
    }
}
