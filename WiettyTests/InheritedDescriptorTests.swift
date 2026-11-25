import Darwin
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// A child the app starts gets its standard streams and nothing else (issue 85).
///
/// Each test opens what the app has open while it runs, a listening Unix socket
/// and a plain file, both WITHOUT `FD_CLOEXEC`, then starts a child through one of
/// the app's spawn sites and has it list its own descriptors. Neither number may
/// be in that list; 0, 1 and 2 must be.
///
/// The list comes from `/bin/ls -1 /dev/fd`. On Darwin `/dev/fd` is the `fdesc`
/// file system, which lists every descriptor the reading process has open, and a
/// pty does not change that: it is the descriptor table, not the terminal, being
/// read. `ls` opens the directory itself and shows that one too, which is why the
/// bait is moved up to 64 and above, out of reach of the low numbers `ls` and the
/// shell use. `lsof` would give the same answer at many times the cost.
@Suite struct InheritedDescriptorTests {
    /// The descriptors a child must not see, closed by `release()`.
    private final class Bait {
        let listener: Int32
        let file: Int32
        private let path: String

        init() throws {
            // `/tmp`, not `TestScratch`: `sun_path` holds 104 bytes.
            let path = "/tmp/wfd-\(UUID().uuidString.prefix(8)).sock"
            self.path = path
            let raw = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(raw >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0)
            try #require(listen(raw, 1) == 0)
            // `F_DUPFD` gives the copy no `FD_CLOEXEC`, whatever the original had.
            listener = fcntl(raw, F_DUPFD, 64)
            close(raw)
            let opened = open("/dev/null", O_RDONLY)
            try #require(opened >= 0)
            file = fcntl(opened, F_DUPFD, 64)
            close(opened)
            try #require(listener >= 64 && file >= 64)
            try #require(fcntl(listener, F_GETFD) & FD_CLOEXEC == 0)
            try #require(fcntl(file, F_GETFD) & FD_CLOEXEC == 0)
        }

        func release() {
            Darwin.close(listener)
            Darwin.close(file)
            unlink(path)
        }
    }

    /// The command every shell based test runs. The markers fence the list off from
    /// anything a login shell's profile prints.
    private static let listing = "printf 'FDS-BEGIN\\n'; /bin/ls -1 /dev/fd; printf 'FDS-END\\n'"

    /// The numbers between the markers, or every number when there are none.
    private static func descriptors(in output: String) -> Set<Int32> {
        var text = Substring(output)
        if let begin = text.range(of: "FDS-BEGIN") { text = text[begin.upperBound...] }
        if let end = text.range(of: "FDS-END") { text = text[..<end.lowerBound] }
        return Set(text.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) })
    }

    private static func expectOnlyStandardStreams(_ seen: Set<Int32>, bait: Bait,
                                                  sourceLocation: SourceLocation = #_sourceLocation) {
        print("child descriptors: \(seen.sorted()); bait: \(bait.listener), \(bait.file)")
        #expect(seen.isSuperset(of: [0, 1, 2]), "child descriptors: \(seen.sorted())",
                sourceLocation: sourceLocation)
        #expect(!seen.contains(bait.listener), "the listening socket reached the child",
                sourceLocation: sourceLocation)
        #expect(!seen.contains(bait.file), "the open file reached the child",
                sourceLocation: sourceLocation)
    }

    private final class TextSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        var text: String { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ bytes: [UInt8], marker: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            storage += String(decoding: bytes, as: UTF8.self)
            return storage.contains(marker)
        }
    }

    /// Every terminal's shell.
    @Test func aTerminalsShellInheritsOnlyItsTerminal() throws {
        let bait = try Bait()
        defer { bait.release() }
        let pty = try RawPTY.spawn(command: Self.listing, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let sink = TextSink()
        let found = DispatchSemaphore(value: 0)
        pty.startReading(onBytes: { bytes in
            if sink.append(bytes, marker: "FDS-END") { found.signal() }
        }, onExit: { _ in })
        try #require(found.wait(timeout: .now() + 5) == .success, "no listing: \(sink.text)")
        Self.expectOnlyStandardStreams(Self.descriptors(in: sink.text), bait: bait)
    }

    /// Managed processes, tests and checks.
    @MainActor
    @Test func aManagedProcessInheritsOnlyItsTerminal() async throws {
        let bait = try Bait()
        defer { bait.release() }
        var output = ""
        var exit: Int32?
        _ = try PTYProcessLauncher(spawnsFromTestHost: true).launch(
            command: Self.listing, directory: URL(fileURLWithPath: "/tmp"), environment: [:],
            onOutput: { output += $0 },
            onExit: { exit = $0 }
        )
        let start = ContinuousClock.now
        while !(exit != nil && output.contains("FDS-END")) {
            try #require(ContinuousClock.now - start < .seconds(5), "no listing: \(output)")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(exit == 0)
        Self.expectOnlyStandardStreams(Self.descriptors(in: output), bait: bait)
    }

    /// The git and freshness probes, which run through Foundation's `Process`. That
    /// closes everything above 2 by itself; this holds it to that.
    @Test func aCommandRunByProcessInheritsOnlyItsPipes() throws {
        let bait = try Bait()
        defer { bait.release() }
        let result = ProcessCommandRunner().run("/bin/ls", ["-1", "/dev/fd"], workingDirectory: nil)
        try #require(result.status == 0, "ls failed: \(result.stderr)")
        Self.expectOnlyStandardStreams(Self.descriptors(in: result.stdout), bait: bait)
    }
}
