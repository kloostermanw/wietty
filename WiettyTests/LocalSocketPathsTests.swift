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

    @Test func aRelativeDirectoryIsRefused() {
        #expect(throws: TerminalRelayError.relativeSocketPath("tmp/wty-7.sock")) {
            _ = try LocalSocketPaths.server(pid: 7, in: "tmp/")
        }
    }

    /// A name that fits while the private bind path made for it does not fails here,
    /// not later at the bind.
    @Test func aNameWhoseBindPathDoesNotFitThrowsAlready() throws {
        // 92 bytes of directory: `wty-1.sock` makes 102, `.wty-XXXXXX/s` makes 105.
        let directory = "/" + String(repeating: "d", count: 90) + "/"
        #expect(throws: TerminalRelayError.socketPathTooLong(directory + ".wty-XXXXXX/s")) {
            _ = try LocalSocketPaths.server(pid: 1, in: directory)
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

    // MARK: sweep, the private bind directories

    private func makePrivateDirectory(_ path: String, socket: Bool = false, files: [String] = [],
                                      age: TimeInterval = 7200) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        if socket { try makeSocketFile(path + "/s") }
        for name in files { FileManager.default.createFile(atPath: path + "/" + name, contents: Data([1])) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                              ofItemAtPath: path)
    }

    @Test func sweepRemovesAnOldPrivateDirectoryThatIsEmptyOrHoldsItsSocket() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let empty = directory + ".wty-Ab3dE9"
        let holding = directory + ".wty-000000"
        try makePrivateDirectory(empty)
        try makePrivateDirectory(holding, socket: true)

        let removed = LocalSocketPaths.sweep(in: directory)

        #expect(Set(removed) == [empty, holding])
        #expect(!exists(empty))
        #expect(!exists(holding))
    }

    @Test func sweepKeepsAPrivateDirectoryThatIsRecent() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let fresh = directory + ".wty-abcdef"
        try makePrivateDirectory(fresh, socket: true, age: 60)
        #expect(LocalSocketPaths.sweep(in: directory).isEmpty)
        #expect(exists(fresh + "/s"))
    }

    @Test func sweepKeepsAPrivateDirectoryHoldingAnythingElse() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let plainS = directory + ".wty-aaaaaa"
        let socketAndMore = directory + ".wty-bbbbbb"
        let otherSocket = directory + ".wty-cccccc"
        try makePrivateDirectory(plainS, files: ["s"])
        try makePrivateDirectory(socketAndMore, socket: true, files: ["t"])
        try FileManager.default.createDirectory(atPath: otherSocket, withIntermediateDirectories: false)
        try makeSocketFile(otherSocket + "/t")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                              ofItemAtPath: otherSocket)

        #expect(LocalSocketPaths.sweep(in: directory).isEmpty)
        #expect(exists(plainS + "/s"))
        #expect(exists(socketAndMore + "/s"))
        #expect(exists(socketAndMore + "/t"))
        #expect(exists(otherSocket + "/t"))
    }

    @Test func sweepKeepsALinkNamedLikeAPrivateDirectory() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let outside = try makeDirectory()
        defer { removeDirectory(outside) }
        let target = outside + "old"
        try makePrivateDirectory(target, socket: true)
        let link = directory + ".wty-linked"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        #expect(LocalSocketPaths.sweep(in: directory).isEmpty)
        #expect(exists(link))
        #expect(exists(target + "/s"))
    }

    @Test func sweepKeepsADirectoryNotNamedExactlyAsTheTemplate() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let names = [".wty-abcde", ".wty-abcdefg", ".wty-abc_ef", ".wty-abc-ef", ".wtx-abcdef", "wty-abcdef",
                     ".wty-abcdé"]
        for name in names { try makePrivateDirectory(directory + name) }
        #expect(LocalSocketPaths.sweep(in: directory).isEmpty)
        for name in names { #expect(exists(directory + name)) }
    }

    @Test func sweepOfAMissingDirectoryRemovesNothing() {
        #expect(LocalSocketPaths.sweep(in: "/nonexistent-\(UUID().uuidString)/").isEmpty)
    }
}
