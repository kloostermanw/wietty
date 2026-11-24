import Darwin
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The names of the local stream sockets, and the sweep that removes the ones a
/// dead process left behind. Every sweep runs in a private directory of its own,
/// so it can never touch a socket of the running app or of another suite.
@Suite struct LocalSocketPathsTests {
    /// A pid no process can have: macOS never hands out one above 99,999.
    private static let freePid: pid_t = 1_000_000

    @Test func serverNameCarriesThePid() throws {
        #expect(try LocalSocketPaths.server(pid: 42, in: "/tmp/x/") == "/tmp/x/wty-42.sock")
    }

    @Test func bridgeNameCarriesThePidAndTheSequence() throws {
        #expect(try LocalSocketPaths.bridge(3, pid: 42, in: "/tmp/x/") == "/tmp/x/wty-42-3.sock")
    }

    @Test func aDirectoryWithoutItsSlashStillGetsOne() throws {
        #expect(try LocalSocketPaths.server(pid: 7, in: "/tmp/x") == "/tmp/x/wty-7.sock")
    }

    @Test func theDefaultsAreThisProcessInTheTemporaryDirectory() throws {
        let path = try LocalSocketPaths.server()
        #expect(path == NSTemporaryDirectory() + "wty-\(getpid()).sock")
    }

    @Test func aPathThatDoesNotFitSunPathThrows() {
        let directory = "/" + String(repeating: "d", count: 95) + "/"
        #expect(throws: TerminalRelayError.self) {
            _ = try LocalSocketPaths.server(pid: 1234, in: directory)
        }
        #expect(throws: TerminalRelayError.self) {
            _ = try LocalSocketPaths.bridge(12, pid: 1234, in: directory)
        }
    }

    // MARK: sweep

    private func makeDirectory() throws -> String {
        var template = Array((NSTemporaryDirectory() + "swpXXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw TerminalRelayError.socketFailed(errno) }
        return String(cString: made) + "/"
    }

    private func removeDirectory(_ directory: String) {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Leaves a real socket file behind, as a crashed run does.
    private func makeSocketFile(_ path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw TerminalRelayError.bindFailed(errno) }
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    @Test func sweepRemovesTheSocketsOfAProcessThatIsGone() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let server = directory + "wty-\(Self.freePid).sock"
        let bridge = directory + "wty-\(Self.freePid)-3.sock"
        try makeSocketFile(server)
        try makeSocketFile(bridge)

        let removed = LocalSocketPaths.sweep(in: directory)

        #expect(Set(removed) == [server, bridge])
        #expect(!exists(server))
        #expect(!exists(bridge))
    }

    @Test func sweepKeepsTheSocketsOfALiveProcess() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let own = directory + "wty-\(getpid()).sock"
        let ownBridge = directory + "wty-\(getpid())-2.sock"
        // launchd: alive, and another user's, so `kill` answers EPERM, not ESRCH.
        let foreign = directory + "wty-1.sock"
        for path in [own, ownBridge, foreign] { try makeSocketFile(path) }

        let removed = LocalSocketPaths.sweep(in: directory)

        #expect(removed.isEmpty)
        for path in [own, ownBridge, foreign] { #expect(exists(path)) }
    }

    @Test func sweepKeepsWhatItDoesNotOwn() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let names = ["wty-\(Self.freePid).socket", "wty-abc.sock", "wty-\(Self.freePid)-.sock",
                     "wty--\(Self.freePid).sock", "xwty-\(Self.freePid).sock",
                     "wty-\(Self.freePid)-1-2.sock", "wty-\(Self.freePid).sock.bak"]
        for name in names { try makeSocketFile(directory + name) }
        // An owned name that is a directory, and one that is a link leading out of
        // the directory to a socket of the same dead pid's shape.
        let folder = directory + "wty-\(Self.freePid + 1).sock"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let outside = try makeDirectory()
        defer { removeDirectory(outside) }
        let target = outside + "wty-\(Self.freePid + 2).sock"
        try makeSocketFile(target)
        let link = directory + "wty-\(Self.freePid + 3).sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        // A regular file with an owned name is not a socket this code made.
        let plain = directory + "wty-\(Self.freePid + 4).sock"
        FileManager.default.createFile(atPath: plain, contents: Data([1]))

        let removed = LocalSocketPaths.sweep(in: directory)

        #expect(removed.isEmpty)
        for name in names { #expect(exists(directory + name)) }
        #expect(exists(folder))
        #expect(exists(link))
        #expect(exists(target))
        #expect(exists(plain))
    }

    @Test func sweepAppliesTheHourRuleToTheOldNames() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let old = directory + "ipx-0123456789ab.sock"
        let fresh = directory + "ipx-ba9876543210.sock"
        let unrelated = directory + "ipz-0123456789ab.sock"
        for path in [old, fresh, unrelated] { try makeSocketFile(path) }
        let twoHoursAgo = Date(timeIntervalSinceNow: -7200)
        for path in [old, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: path)
        }

        let removed = LocalSocketPaths.sweep(in: directory)

        #expect(removed == [old])
        #expect(!exists(old))
        #expect(exists(fresh))
        #expect(exists(unrelated))
    }

    @Test func sweepOfAMissingDirectoryRemovesNothing() {
        #expect(LocalSocketPaths.sweep(in: "/nonexistent-\(UUID().uuidString)/").isEmpty)
    }
}
