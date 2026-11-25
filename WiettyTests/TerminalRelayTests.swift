import Darwin
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// What is left of the relay: it reads the pty, once started, and hands every chunk
/// to its callback. The surface's half (the helper's socket) is the pane's bridge
/// now, and `OwnPaneStreamTests` covers the route end to end.
@Suite struct TerminalRelayTests {
    /// Lock-guarded accumulator, not a captured `var`: the output handler is
    /// `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a
    /// captured local, the same reason `PaneStreamHubTests` uses `Sink`.
    private final class TextSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        private var exits = 0
        var text: String { lock.lock(); defer { lock.unlock() }; return storage }
        var exitCount: Int { lock.lock(); defer { lock.unlock() }; return exits }
        func append(_ bytes: [UInt8]) {
            lock.lock(); storage += String(decoding: bytes, as: UTF8.self); lock.unlock()
        }
        func exited() { lock.lock(); exits += 1; lock.unlock() }
    }

    private func spawn(_ command: String) throws -> RawPTY {
        try RawPTY.spawn(command: command, directory: URL(fileURLWithPath: "/tmp"),
                         environment: [:], size: TerminalSize(cols: 80, rows: 24),
                         shell: "/bin/sh")
    }

    /// Every chunk the child writes reaches `onOutput`, which is what reaches the
    /// hub and every viewer, the pane's own included. The marker is arithmetic, so
    /// the pty's echo of the command line cannot satisfy it.
    @Test func outputReachesTheCallback() throws {
        let pty = try spawn("echo read-$((70+7)); sleep 5")
        defer { pty.terminate() }
        let seen = TextSink()
        let relay = TerminalRelay(pty: pty) { seen.append($0) }
        defer { relay.stop() }
        relay.start(onExit: { _ in })
        #expect(waitUntil { seen.text.contains("read-77") })
    }

    /// Nothing is read before `start`: the output waits in the pty. This is what
    /// lets `GhosttyService` hold a terminal's reading until its pane has attached.
    @Test func nothingIsReadBeforeStart() throws {
        let pty = try spawn("echo early-$((40+2)); sleep 5")
        defer { pty.terminate() }
        let seen = TextSink()
        let relay = TerminalRelay(pty: pty) { seen.append($0) }
        defer { relay.stop() }
        Thread.sleep(forTimeInterval: 0.4)
        #expect(seen.text.isEmpty)
        #expect(relay.hasStarted == false)
        relay.start(onExit: { _ in })
        #expect(waitUntil { seen.text.contains("early-42") })
    }

    /// A relay stopped before it started never reads: a terminal closed before its
    /// pane attached must not start reading a pty that is being terminated.
    @Test func aStartAfterStopDoesNothing() throws {
        let pty = try spawn("echo never-$((1+1)); sleep 5")
        defer { pty.terminate() }
        let seen = TextSink()
        let relay = TerminalRelay(pty: pty) { seen.append($0) }
        relay.stop()
        relay.start(onExit: { _ in })
        #expect(relay.hasStarted == false)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(seen.text.isEmpty)
    }

    /// Reading starts once however often `start` is called, so the pane attaching
    /// and the wait for it running out cannot both start it: every byte arrives
    /// once, and the exit is reported once.
    @Test func aSecondStartIsIgnored() throws {
        let pty = try spawn("echo once-$((5+5))")
        defer { pty.terminate() }
        let seen = TextSink()
        let relay = TerminalRelay(pty: pty) { seen.append($0) }
        defer { relay.stop() }
        relay.start(onExit: { _ in seen.exited() })
        relay.start(onExit: { _ in seen.exited() })
        #expect(waitUntil { seen.exitCount > 0 })
        Thread.sleep(forTimeInterval: 0.2)
        #expect(seen.exitCount == 1)
        #expect(seen.text.components(separatedBy: "once-10").count == 2)
    }
}
