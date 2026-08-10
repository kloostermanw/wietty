import Testing
import Foundation
import Darwin
@testable import Wietty

/// The bundled helper. It is the one piece of this substrate that runs as its own
/// process, so it is exercised as one: built, launched, and talked to over a real
/// socket.
@Suite struct WiettyPtyHelperTests {
    /// Where the helper is at runtime. Shared with
    /// `RelayHelperIntegrationTests`, which runs the same binary against a real
    /// relay; see `bundledHelperURL`.
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
