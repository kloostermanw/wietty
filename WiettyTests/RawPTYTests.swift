import Testing
import Foundation
import Darwin
@testable import Wietty

/// The PTY Wietty owns. Every property asserted here is one the libghostty
/// substrate depends on and `PTYProcessLauncher` cannot provide: a live master
/// fd, a resizable window, a readable foreground job, and raw bytes.
@Suite struct RawPTYTests {
    /// Lock-guarded accumulator, not a captured `var`: the byte handler is
    /// `@Sendable` and Swift 6 refuses a `@Sendable` closure that mutates a
    /// captured local, the same reason `PaneStreamHubTests` uses `Sink` and
    /// `BellRecorder`.
    private final class TextSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        var text: String { lock.lock(); defer { lock.unlock() }; return storage }
        /// Appends a chunk and reports whether `marker` is present afterwards.
        func append(_ bytes: [UInt8], marker: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            storage += String(decoding: bytes, as: UTF8.self)
            return storage.contains(marker)
        }
    }

    /// Same reason as `TextSink`: the exit handler is `@Sendable`.
    private final class ExitStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Int32 = -1
        var code: Int32 { lock.lock(); defer { lock.unlock() }; return storage }
        func record(_ status: Int32) { lock.lock(); storage = status; lock.unlock() }
    }

    /// Collects output until `marker` is seen, or the deadline passes. Terminal
    /// output arrives in arbitrarily many chunks, so asserting on the first one
    /// is a flake.
    private func collect(_ pty: RawPTY, until marker: String,
                         timeout: TimeInterval = 5) -> String {
        let sink = TextSink()
        let found = DispatchSemaphore(value: 0)
        pty.startReading(onBytes: { bytes in
            if sink.append(bytes, marker: marker) { found.signal() }
        }, onExit: { _ in })
        _ = found.wait(timeout: .now() + timeout)
        return sink.text
    }

    @Test func itRunsACommandAndReportsItsOutput() throws {
        let pty = try RawPTY.spawn(command: "echo ready-42", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        #expect(collect(pty, until: "ready-42").contains("ready-42"))
    }

    /// The working directory is the workspace folder, and a terminal that opens
    /// somewhere else is useless.
    @Test func itStartsInTheGivenDirectory() throws {
        let pty = try RawPTY.spawn(command: "pwd", directory: URL(fileURLWithPath: "/usr/lib"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        #expect(collect(pty, until: "/usr/lib").contains("/usr/lib"))
    }

    /// The size has to be set on the pty before the child runs, not after: a
    /// full screen program started at the default 80x24 lays itself out once.
    @Test func theInitialSizeReachesTheChild() throws {
        let pty = try RawPTY.spawn(command: "stty size", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 132, rows: 43),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        #expect(collect(pty, until: "43 132").contains("43 132"))
    }

    /// The surface's geometry is the only sizing authority on this substrate, and
    /// it arrives after the terminal already exists, so a resize has to land on a
    /// running child.
    @Test func aResizeReachesTheRunningChild() throws {
        // The trap body runs only once the foreground command returns, which is
        // the shell's own semantics, so the command has to be something that
        // returns promptly and keeps the shell alive. A single `sleep 5` would
        // report the new size a whole five seconds later, right at the deadline.
        let pty = try RawPTY.spawn(command: "trap 'stty size' WINCH; while true; do sleep 0.1; done",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let sink = TextSink()
        let found = DispatchSemaphore(value: 0)
        pty.startReading(onBytes: { bytes in
            if sink.append(bytes, marker: "30 100") { found.signal() }
        }, onExit: { _ in })
        // The trap has to be installed before the signal, and there is no event
        // that says so. A short settle is the honest way to wait for a shell
        // reaching its first read.
        Thread.sleep(forTimeInterval: 0.5)
        pty.resize(to: TerminalSize(cols: 100, rows: 30))
        #expect(found.wait(timeout: .now() + 5) == .success)
    }

    /// Input goes to the master, and the pty's line discipline is what makes it
    /// behave like a terminal. This is also what carries a remote viewer's
    /// keystrokes, so it is not only the local path.
    @Test func writtenInputReachesTheShell() throws {
        let pty = try RawPTY.spawn(command: nil, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let sink = TextSink()
        let found = DispatchSemaphore(value: 0)
        pty.startReading(onBytes: { bytes in
            if sink.append(bytes, marker: "typed-99") { found.signal() }
        }, onExit: { _ in })
        Thread.sleep(forTimeInterval: 0.5)
        // The marker is computed by the shell, never typed. A pty echoes whatever
        // is written to the master back out of it, so a literal `echo typed-99`
        // would appear in the output whether or not any shell was there to run it,
        // and this test would pass against a dead terminal. Only execution turns
        // `$((90+9))` into `99`.
        pty.write(Array("echo typed-$((90+9))\n".utf8))
        #expect(found.wait(timeout: .now() + 5) == .success)
    }

    /// The polled job name. `ProjectStore.runState` decides whether an agent is
    /// running from this, and `ProjectStore.activate` types `claude` into a row
    /// it believes is idle, so a wrong answer submits text into a live agent.
    @Test func theForegroundJobIsReadable() throws {
        let pty = try RawPTY.spawn(command: "sleep 5", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        pty.startReading(onBytes: { _ in }, onExit: { _ in })
        Thread.sleep(forTimeInterval: 0.7)
        #expect(pty.foregroundJobName() == "sleep")
    }

    /// A child that exits has to be reported, because that is the only source of
    /// `.terminated` on this substrate. Without it a finished row stays marked
    /// running for the life of the app.
    @Test func anExitIsReported() throws {
        let pty = try RawPTY.spawn(command: "exit 3", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        let exited = DispatchSemaphore(value: 0)
        let reported = ExitStatus()
        pty.startReading(onBytes: { _ in }, onExit: { status in
            reported.record(status)
            exited.signal()
        })
        #expect(exited.wait(timeout: .now() + 5) == .success)
        #expect(reported.code == 3)
    }

    /// A keystroke arriving after the shell has exited must go nowhere.
    ///
    /// The dangerous version of this is not a crash. The EOF path closes the master
    /// from the read source's cancel handler, without `terminate` ever being
    /// called, and the kernel hands out the lowest free descriptor number, so the
    /// number the terminal used is very soon something else: a log file, a socket,
    /// a database handle. A late write then lands in that. The test forces exactly
    /// that collision with `dup2` rather than hoping for it.
    @Test func aWriteAfterTheChildExitedGoesNowhere() throws {
        let pty = try RawPTY.spawn(command: "exit 0", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        let exited = DispatchSemaphore(value: 0)
        pty.startReading(onBytes: { _ in }, onExit: { _ in exited.signal() })
        #expect(exited.wait(timeout: .now() + 5) == .success)

        // Wait for the stream to reach EOF and close the master, which is a
        // separate event from the child exiting.
        let deadline = Date().addingTimeInterval(5)
        while fcntl(pty.masterFd, F_GETFD) != -1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(fcntl(pty.masterFd, F_GETFD) == -1, "the master should be closed after EOF")

        // Put an innocent file on precisely the descriptor number the terminal used.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-pty-recycled-\(UUID().uuidString)").path
        let scratch = open(path, O_CREAT | O_RDWR, 0o600)
        #expect(scratch >= 0)
        defer { close(scratch); unlink(path) }
        #expect(dup2(scratch, pty.masterFd) == pty.masterFd)

        pty.write(Array("rm -rf /\n".utf8))
        // A write is handed to the pty's own queue, so the barrier is what makes this
        // an assertion about where the bytes went rather than about which thread won.
        pty.waitForPendingWrites()
        pty.terminate()

        var info = stat()
        #expect(fstat(scratch, &info) == 0)
        #expect(info.st_size == 0, "input was written into a recycled descriptor")
        // `terminate` must not close the descriptor it no longer owns either.
        #expect(fcntl(scratch, F_GETFD) != -1)
        close(pty.masterFd)
    }

    /// A terminal torn down before it ever started reading still has to be waited
    /// on, or the child stays a zombie in the process table for the life of the
    /// app. `GhosttyService.open` has two paths that reach exactly this state: a
    /// relay that will not bind and a surface that will not create both terminate
    /// a pty whose reader was never started.
    ///
    /// Asserted by asking for the child again: a `waitpid` that answers ECHILD
    /// means something already reaped it, while an unreaped zombie would be
    /// handed straight back.
    ///
    /// Torn down with no settle at all, deliberately. That is the harder case and
    /// the one the failure paths actually produce: the child has not reached the
    /// `setsid` that `forkpty` performs for it, so it is still in Wietty's own
    /// process group and `killpg` addresses a group that does not exist. Before
    /// `terminate` signalled the child directly as well, this left a live login
    /// shell 5 runs out of 5 rather than a zombie.
    @Test func aTerminalTornDownBeforeReadingIsStillReaped() throws {
        let pty = try RawPTY.spawn(command: "sleep 30", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        let child = pty.pid
        pty.terminate()
        var reaped = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !reaped {
            var status: Int32 = 0
            let answer = waitpid(child, &status, WNOHANG)
            if answer == -1, errno == ECHILD { reaped = true; break }
            #expect(answer == 0, "the child was still a zombie waiting to be collected")
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(reaped)
    }

    /// `terminate` targets the group, not the pid. A terminal closed while a
    /// pipeline is running must take the whole tree, or the app leaks processes
    /// that keep writing into a pty nobody reads.
    @Test func terminateTakesTheWholeGroup() throws {
        let pty = try RawPTY.spawn(command: "sleep 30 & sleep 30", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        pty.startReading(onBytes: { _ in }, onExit: { _ in })
        Thread.sleep(forTimeInterval: 0.5)
        let group = pty.pid
        pty.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        // killpg with signal 0 asks whether the group still exists.
        #expect(killpg(group, 0) == -1)
    }

    /// TERM is what a program reads to decide what it may emit. Ghostty renders
    /// the bytes, so `xterm-ghostty` is the truthful answer, but only when that
    /// terminfo entry exists: naming an entry the database does not hold breaks
    /// every ncurses program. Either way it must not be inherited from whatever
    /// launched the app.
    @Test func termNamesTheRenderer() throws {
        #expect(["xterm-ghostty", "xterm-256color"].contains(RawPTY.terminalType))
        let pty = try RawPTY.spawn(command: "echo $TERM", directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        #expect(collect(pty, until: RawPTY.terminalType).contains(RawPTY.terminalType))
    }

    /// TERM says what may be drawn; TERM_PROGRAM says who is drawing it. A program
    /// that adapts to its host terminal reads the second, and an agent picks
    /// between the bell, OSC 9 and OSC 777 by it. Left unset it emits none of them,
    /// which is a terminal that handles all three being told about nothing. It must
    /// also not be inherited: whatever launched Wietty is not what the shell is
    /// talking to.
    @Test func termProgramNamesThisApp() throws {
        let pty = try RawPTY.spawn(command: "echo \"[$TERM_PROGRAM/$TERM_PROGRAM_VERSION]\"",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let expected = "[\(RawPTY.programName)/\(AppVersion.current)]"
        #expect(collect(pty, until: expected).contains(expected))
    }

    /// And it wins over an inherited value rather than deferring to it. The caller's
    /// environment is the same door a stale `TERM_PROGRAM` comes through when Wietty
    /// is launched from another terminal, so the override is asserted at the point
    /// it would be lost.
    @Test func termProgramOverridesAnInheritedValue() throws {
        let pty = try RawPTY.spawn(command: "echo \"[$TERM_PROGRAM]\"",
                                   directory: URL(fileURLWithPath: "/tmp"),
                                   environment: ["TERM_PROGRAM": "iTerm.app"],
                                   size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let expected = "[\(RawPTY.programName)]"
        #expect(collect(pty, until: expected).contains(expected))
    }

    /// Job control, which is the whole reason this uses `forkpty` rather than
    /// `posix_spawn`. Without a controlling terminal `^C` kills the shell along
    /// with the foreground command, so the terminal is dead after the first
    /// interrupt. The spike measured exactly that failure, so it is asserted here
    /// rather than only at the relay level.
    @Test func controlCInterruptsTheCommandAndNotTheShell() throws {
        let pty = try RawPTY.spawn(command: nil, directory: URL(fileURLWithPath: "/tmp"),
                                   environment: [:], size: TerminalSize(cols: 80, rows: 24),
                                   shell: "/bin/zsh")
        defer { pty.terminate() }
        let sink = TextSink()
        let survived = DispatchSemaphore(value: 0)
        pty.startReading(onBytes: { bytes in
            // "still-here-64" is printed by the shell only if it is still alive
            // after the interrupt, and only if the interrupt actually returned it
            // to a prompt.
            if sink.append(bytes, marker: "still-here-64") { survived.signal() }
        }, onExit: { _ in })
        Thread.sleep(forTimeInterval: 0.6)
        pty.write(Array("sleep 30\n".utf8))
        Thread.sleep(forTimeInterval: 0.6)
        pty.write([0x03])
        Thread.sleep(forTimeInterval: 0.4)
        // The marker is arithmetic the shell has to evaluate, not a literal. The
        // pty's line discipline echoes every byte written to the master straight
        // back out of it, so a typed `echo still-here-64` shows up in the output
        // even when the shell is still blocked in `sleep 30` and the interrupt
        // reached nothing, which is precisely the failure this test exists to
        // catch. Echo can only reproduce `$((32+32))`; `64` means execution.
        pty.write(Array("echo still-here-$((32+32))\n".utf8))
        #expect(survived.wait(timeout: .now() + 6) == .success)
    }
}
