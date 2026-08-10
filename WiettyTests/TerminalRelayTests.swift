import Testing
import Foundation
import Darwin
@testable import Wietty

/// The socket end Wietty owns. The helper on the other side is a dumb pipe,
/// so every property that makes this behave like a terminal is asserted here.
@Suite struct TerminalRelayTests {
    /// Stands in for `wietty-pty`: connects, and exposes the two directions.
    private final class FakeHelper {
        let fd: Int32
        private var open = true
        init(path: String) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
                close(fd)
                throw TerminalRelayError.socketFailed(code)
            }
        }
        deinit { disconnect() }

        /// Goes away the way the real helper does, as the surface's child dying.
        func disconnect() {
            guard open else { return }
            open = false
            close(fd)
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress!, $0.count) }
        }

        func read(until marker: String, timeout: TimeInterval = 5) -> String {
            var text = ""
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&readable, 1, 200) > 0 else { continue }
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                text += String(decoding: buffer[0..<count], as: UTF8.self)
                if text.contains(marker) { break }
            }
            return text
        }
    }

    /// Lock-guarded accumulator, not a captured `var`: the output handler is
    /// `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a
    /// captured local, the same reason `PaneStreamHubTests` uses `Sink`.
    private final class TextSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        private var total = 0
        var text: String { lock.lock(); defer { lock.unlock() }; return storage }
        /// Total bytes seen. Kept separately so a test can watch the stream keep
        /// moving without holding a flood of output in memory.
        var byteCount: Int { lock.lock(); defer { lock.unlock() }; return total }
        func append(_ bytes: [UInt8]) {
            lock.lock()
            total += bytes.count
            if total < 1 << 16 { storage += String(decoding: bytes, as: UTF8.self) }
            lock.unlock()
        }
    }

    private func uniquePath() -> String {
        NSTemporaryDirectory() + "ipx-t\(UInt32.random(in: 0..<0xFFFFFF)).sock"
    }

    /// sun_path is 104 bytes including the terminator, and the per user temp
    /// directory already spends roughly half of it. A path that does not fit must
    /// fail loudly rather than bind a silently truncated one, which would leave
    /// the helper connecting to a socket nobody listens on.
    ///
    /// The directory is what can overflow the budget, not the id: the id is
    /// truncated to a fixed width, while the directory is inherited from the
    /// environment. So it is injected rather than hoped about.
    @Test func anOverlongPathIsRefused() {
        let long = "/" + String(repeating: "x", count: 200) + "/"
        #expect(throws: TerminalRelayError.self) {
            _ = try TerminalRelay.socketPath(for: "gt:" + UUID().uuidString.lowercased(),
                                             in: long)
        }
    }

    @Test func aDerivedPathFits() throws {
        let path = try TerminalRelay.socketPath(for: "gt:" + UUID().uuidString.lowercased())
        #expect(path.utf8.count < 104)
        #expect(path.hasSuffix(".sock"))
    }

    /// Output goes both ways on the same read: to the helper, which renders it,
    /// and to `onOutput`, which reaches every remote viewer. A substrate that
    /// only fed one of them would show a terminal locally that the browser never
    /// sees, or the reverse.
    @Test func outputReachesBothTheHelperAndTheCallback() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: "echo both-77", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let streamed = TextSink()
        let relay = try TerminalRelay(pty: pty, socketPath: path) { bytes in
            streamed.append(bytes)
        }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        let helper = try FakeHelper(path: path)
        let rendered = helper.read(until: "both-77")
        let seen = streamed.text
        #expect(rendered.contains("both-77"))
        #expect(seen.contains("both-77"))
    }

    /// The shell prints a prompt as soon as it starts, and the surface (and so
    /// the helper) is created after that. Without a pre-connect buffer the local
    /// view opens on a blank screen while the browser saw the prompt, which reads
    /// as a broken terminal.
    @Test func outputBeforeTheHelperConnectsIsNotLost() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: "echo early-11; sleep 5",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        // Let the shell get ahead of the helper on purpose.
        Thread.sleep(forTimeInterval: 0.8)
        let helper = try FakeHelper(path: path)
        #expect(helper.read(until: "early-11").contains("early-11"))
    }

    /// Keystrokes from the surface arrive on the socket and must reach the pty
    /// master, where the line discipline turns them into terminal input.
    ///
    /// The marker is arithmetic the shell has to evaluate. A pty echoes anything
    /// written to the master straight back out of it, so a literal marker would
    /// be satisfied by the echo alone, whether or not a shell ever ran the line.
    /// Echo can only ever reproduce `$((50+5))`.
    @Test func helperInputReachesTheShell() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: nil, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        let helper = try FakeHelper(path: path)
        Thread.sleep(forTimeInterval: 0.6)
        helper.send("echo relayed-$((50+5))\n")
        #expect(helper.read(until: "relayed-55").contains("relayed-55"))
    }

    /// The control character has to arrive as a byte on the master, so the inner
    /// pty raises SIGINT. If it were interpreted anywhere in the relay, a
    /// running command would keep running and a literal ^C would appear.
    ///
    /// The interrupt and the marker are sent as two separate lines. `^C` in zsh
    /// abandons the rest of the command line, so a trailing `; echo …` on the
    /// interrupted line would never run; and the echoed keystrokes would carry a
    /// literal marker back regardless. Only a shell that came back to a prompt
    /// can produce `interrupted-8` out of `$((4+4))`.
    @Test func controlCReachesTheShellAsASignal() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: nil, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        let helper = try FakeHelper(path: path)
        Thread.sleep(forTimeInterval: 0.6)
        helper.send("sleep 30\n")
        Thread.sleep(forTimeInterval: 0.6)
        helper.send("\u{03}")
        Thread.sleep(forTimeInterval: 0.4)
        helper.send("echo interrupted-$((4+4))\n")
        #expect(helper.read(until: "interrupted-8").contains("interrupted-8"))
    }

    /// Stopping must unlink the socket file. Left behind, a crashed run's file
    /// makes the next bind on the same id fail, and the id is derived from the
    /// session so it does recur.
    @Test func stopUnlinksTheSocket() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: "sleep 5", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
        relay.start(onExit: { _ in })
        #expect(FileManager.default.fileExists(atPath: path))
        relay.stop()
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    /// The helper is a child of the libghostty surface, so it goes away whenever a
    /// terminal is closed, and it can go away in the middle of a write. Without
    /// `SO_NOSIGPIPE` that write raises SIGPIPE, whose default disposition kills
    /// the process: not a dropped frame, the whole app. This test dies with the
    /// host rather than failing, which is the loudest a fatal signal can be.
    ///
    /// The helper connects and never reads, so the socket buffer fills and the
    /// relay's write is parked in the kernel at the moment the peer disappears.
    /// A helper that drained the socket would let the relay see EOF first and
    /// never attempt the doomed write, which is why this one is deliberately deaf.
    @Test func aHelperThatDisappearsDuringAWriteDoesNotKillTheApp() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: "while true; do echo spew-$((16+17)); done",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let streamed = TextSink()
        let relay = try TerminalRelay(pty: pty, socketPath: path) { streamed.append($0) }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        let helper = try FakeHelper(path: path)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(streamed.text.contains("spew-33"))
        let stalled = streamed.byteCount
        helper.disconnect()
        Thread.sleep(forTimeInterval: 0.3)
        // Reaching this at all is the point; that the stream resumed says the
        // failed write released the pty's read source rather than wedging it.
        #expect(streamed.byteCount > stalled)
    }

    /// A helper that stops reading parks the relay's write, and with it the pty's
    /// read source, since output is written to both on the one read. Remote
    /// viewers go silent along with the surface. Tearing the terminal down has to
    /// give that thread back, and neither cancelling the source nor closing the
    /// descriptor can do it while a write is holding it, so the socket is shut
    /// down first.
    @Test func stopReleasesAWriteParkedOnADeafHelper() throws {
        let path = uniquePath()
        let pty = try RawPTY.spawn(command: "while true; do echo park-$((21+21)); done",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let streamed = TextSink()
        let relay = try TerminalRelay(pty: pty, socketPath: path) { streamed.append($0) }
        let helper = try FakeHelper(path: path)
        defer { helper.disconnect() }
        relay.start(onExit: { _ in })
        // `FakeHelper` reads only when asked, so it is deaf for this whole test:
        // the socket buffer fills and the write parks.
        Thread.sleep(forTimeInterval: 0.5)
        let parked = streamed.byteCount
        Thread.sleep(forTimeInterval: 0.3)
        #expect(streamed.byteCount == parked)   // confirms it really is stuck
        relay.stop()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(streamed.byteCount > parked)
    }

    /// A stale file from a crashed run must not block a fresh bind. The path is
    /// derived from the session id, so a leftover does recur.
    ///
    /// Asserted by getting a terminal's output through the socket that replaced it,
    /// rather than on the helper's descriptor: a connect that succeeded returns a
    /// descriptor that cannot be negative, so that assertion could not fail once
    /// `init` had returned, and a `bind` onto the stale file would have thrown a line
    /// earlier anyway. Reading a byte the shell produced is the claim that actually
    /// distinguishes a working socket from a bound one.
    @Test func aStaleSocketFileIsReplaced() throws {
        let path = uniquePath()
        FileManager.default.createFile(atPath: path, contents: nil)
        let pty = try RawPTY.spawn(command: "echo replaced-$((3+6))",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let relay = try TerminalRelay(pty: pty, socketPath: path) { _ in }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        let helper = try FakeHelper(path: path)
        defer { helper.disconnect() }
        #expect(helper.read(until: "replaced-9").contains("replaced-9"))
    }
}
