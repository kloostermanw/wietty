import Testing
import Foundation
import Darwin
@testable import Wietty

/// The bundled helper. It is the one piece of this substrate that runs as its own
/// process, so it is exercised as one: built, launched, and talked to over a real
/// socket.
@Suite struct WiettyPtyHelperTests {
    /// Where the helper is at runtime. Shared with `OwnPaneStreamTests`, which runs
    /// the same binary against a real bridge; see `bundledHelperURL`.
    private func helperURL() throws -> URL { try bundledHelperURL() }

    @Test func theHelperIsInTheBundle() throws {
        let url = try helperURL()
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }

    /// The helper connects, then copies both ways and interprets nothing. Run
    /// against a plain socket rather than a pty here: the pty behaviour is
    /// `RawPTY`'s and the raw mode behaviour needs a real tty, which only the
    /// running app has. What this asserts is the copying.
    @Test func itCopiesBytesBothWays() throws {
        let path = NSTemporaryDirectory() + "ipx-h\(UInt32.random(in: 0..<0xFFFFFF)).sock"
        unlink(path)

        let listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(Darwin.listen(listenFd, 1) == 0)
        defer { close(listenFd); unlink(path) }

        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = [path]
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        try process.run()
        defer { process.terminate() }

        let client = Darwin.accept(listenFd, nil, nil)
        #expect(client >= 0)
        defer { close(client) }

        // Helper stdin -> socket.
        toHelper.fileHandleForWriting.write(Data("up-31".utf8))
        var buffer = [UInt8](repeating: 0, count: 64)
        var readable = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        #expect(poll(&readable, 1, 3000) > 0)
        let upCount = Darwin.read(client, &buffer, buffer.count)
        #expect(upCount > 0)
        #expect(String(decoding: buffer[0..<max(upCount, 0)], as: UTF8.self).contains("up-31"))

        // Socket -> helper stdout.
        let down = Array("down-42".utf8)
        down.withUnsafeBytes { _ = Darwin.write(client, $0.baseAddress!, $0.count) }
        let out = fromHelper.fileHandleForReading.readData(ofLength: 7)
        #expect(String(decoding: out, as: UTF8.self) == "down-42")
    }

    /// The helper closes every descriptor it inherited above 2 before it does
    /// anything else. libghostty spawns it and closes nothing, so without that it
    /// would hold whatever the app has open (other terminals' pty masters among
    /// them).
    ///
    /// Shown by behaviour: the helper is spawned holding the write end of a pipe at
    /// descriptor 100, not close on exec, as libghostty would hand it one. Once the
    /// helper is connected and this test has closed its own copy, the read end sees
    /// the end of the pipe only if the helper closed the one it inherited, and the
    /// helper is still running then. Every descriptor this test makes is close on
    /// exec, and reaches the helper only through a `dup2` action of the spawn, so a
    /// child some other test spawns meanwhile cannot hold a copy.
    @Test func theHelperClosesTheDescriptorsItInherited() throws {
        func cloexec(_ fd: Int32) { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        func pipePair() -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            #expect(pipe(&fds) == 0)
            fds.forEach(cloexec)
            return (fds[0], fds[1])
        }

        let path = NSTemporaryDirectory() + "ipx-fd\(UInt32.random(in: 0..<0xFFFFFF)).sock"
        unlink(path)
        let listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        cloexec(listenFd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listenFd, 1) == 0)
        defer { close(listenFd); unlink(path) }

        // Standard input stays open for the whole test (its write end is held
        // here), so the helper does not end on its own before it is looked at.
        let input = pipePair(), output = pipePair(), extra = pipePair()
        defer { close(input.write); close(output.read); close(extra.read) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input.read, 0)
        posix_spawn_file_actions_adddup2(&actions, output.write, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        // A dup2 action clears close on exec on its target: the helper gets this
        // one the way it gets an app descriptor from libghostty.
        posix_spawn_file_actions_adddup2(&actions, extra.write, 100)

        let helper = try helperURL().path
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), strdup(path), nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&pid, helper, &actions, nil, argv, environ)
        close(input.read)
        close(output.write)
        close(extra.write)
        try #require(spawned == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        // Connected: past the close loop, which runs before the socket is made.
        var acceptable = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
        try #require(poll(&acceptable, 1, 5000) > 0)
        let client = Darwin.accept(listenFd, nil, nil)
        try #require(client >= 0)
        defer { close(client) }

        var readable = pollfd(fd: extra.read, events: Int16(POLLIN), revents: 0)
        let ready = poll(&readable, 1, 5000)
        var byte: UInt8 = 0
        let count = ready > 0 ? Darwin.read(extra.read, &byte, 1) : -1
        #expect(ready > 0 && count == 0, "the helper still holds the descriptor it inherited")
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == 0, "the helper is still running")
    }

    /// Wrong usage must fail fast with a distinct status rather than hang. A
    /// surface whose command hangs shows a permanently blank terminal.
    @Test func aMissingArgumentExitsWithUsage() throws {
        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = []
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 64)
    }

    /// A socket nobody listens on means the terminal is already gone. Exiting
    /// tells the surface its child died, which is the truthful outcome.
    @Test func anAbsentSocketExitsRatherThanBlocking() throws {
        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = [NSTemporaryDirectory() + "ipx-nothing-here.sock"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 69)
    }
}
