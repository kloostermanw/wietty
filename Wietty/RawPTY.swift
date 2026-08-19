import Foundation
import Darwin
import os

/// `forkpty` is the one call here that can fail before there is a terminal, and it
/// reports nothing but that it failed. There is deliberately no spawn failure case:
/// the fork returns before the child reaches its `execve`, so a command that cannot
/// be executed is reported by the child's exit status of 127, the way a shell
/// reports it, and never as an error thrown from `spawn`.
enum RawPTYError: Error, Equatable {
    case allocationFailed
}

/// The terminal stack's diagnostic channel.
///
/// The app surfaces a failure to the user through `ProjectStore.lastError`, which is
/// an alert, and that is the better channel whenever there is still a row or a click
/// for the message to belong to. This is for the work that outlives what it belonged
/// to, where an alert would name something the user can no longer see: a keystroke
/// that never reached the pty, a resize that failed halfway, a repaint that could not
/// be built. Logged at the site that would otherwise drop the error, so the discard
/// is recorded instead of invisible.
enum GhosttyLog {
    static let stack = Logger(subsystem: "eu.kloosterman.wietty", category: "ghostty")
}

/// One pseudo-terminal Wietty owns: the master fd, the child's process group,
/// and a raw byte stream off the master.
///
/// `PTYProcessLauncher` runs the same spawn sequence for managed processes and is
/// deliberately not reused. It decodes output to `String` and keeps no reference
/// to the master fd, so it cannot be resized, cannot be written to, and cannot
/// report a foreground job. The two exist side by side because they answer
/// different questions: that one is a logged process, this one is a terminal.
///
/// Bytes are handed out raw rather than decoded. The stream is split into chunks
/// at arbitrary boundaries, so a multi-byte character routinely straddles two
/// reads; decoding here would replace the split half with U+FFFD before
/// `UTF8Chunker` ever saw it. `PaneStreamHub` owns that boundary policy for
/// every substrate.
final class RawPTY: @unchecked Sendable {
    let masterFd: Int32
    /// The child's pid. It becomes its own process group id, because `forkpty` does
    /// a `setsid` in the child, but not until the child runs: between the fork
    /// returning here and that call the child is still in Wietty's own group, so
    /// `killpg(pid, ...)` signals nobody. `hangUp` covers that window by signalling
    /// the group and the pid both, and its comment has the measurement.
    let pid: pid_t

    /// Where every write to the master runs.
    ///
    /// Off the caller's thread, and serial, and both halves are load bearing.
    ///
    /// A write to a master blocks once the child stops reading and the buffer fills,
    /// which is the finding recorded around `withMaster` below. `GhosttyService.send`
    /// is called on the main actor, by the remote keystroke stream and by MCP, so a
    /// paste into a terminal whose foreground program is not reading stdin froze the
    /// whole UI until it did: measured at 5.17 s for a paste into a `sleep 5`, not
    /// inferred. Local keystrokes were never exposed to it, arriving on the relay's
    /// own queue instead, which is what made the freeze look like a remote-only
    /// problem rather than a property of the write.
    ///
    /// The block needs a completed line, not just a full queue: `ptcwrite` parks when
    /// the queue is full and either the canonical queue is non-empty or the tty is
    /// non-canonical. A paste of one enormous line into a canonical tty therefore does
    /// not park, which is worth knowing before writing a probe for this.
    ///
    /// Serial because terminal input order is as load bearing as output order. One
    /// queue per pty keeps every writer's bytes in the order they were handed over,
    /// where a concurrent queue would scramble a paste that arrives as several
    /// chunks. This is the same rule `TmuxStack.onSend` follows with its serial queue,
    /// and the `AsyncStream` in `GhosttyStack` keeps its half of it upstream of here.
    private let writes: DispatchQueue

    private let lock = NSLock()
    private var readSource: DispatchSourceRead?
    private var closed = false
    private var masterClosed = false
    /// Syscalls currently using `masterFd`. The descriptor is not closed while
    /// this is above zero, so no call can be holding a number that has already
    /// been recycled.
    private var inFlightUses = 0
    /// Whether `close(2)` has actually run on `masterFd`, as opposed to
    /// `masterClosed`, which only says no new use may start.
    private var fdClosed = false
    /// Whether a thread is already waiting on the child. Both `startReading` and
    /// `terminate` want one, and two `waitpid` calls on one pid mean the second
    /// gets ECHILD and reports a status nobody ever exited with.
    private var waitStarted = false
    /// Whether the child has been collected. Once it has, its pid is the kernel's
    /// to hand out again and nothing here may signal it.
    private var childReaped = false

    private init(masterFd: Int32, pid: pid_t) {
        self.masterFd = masterFd
        self.pid = pid
        // Labelled per pty, so a queue parked on a write names the terminal it
        // belongs to in a sample.
        self.writes = DispatchQueue(label: "eu.kloosterman.wietty.pty-write-\(pid)")
    }

    /// The TERM to hand the child.
    ///
    /// `xterm-ghostty` is the truthful answer, because Ghostty renders these
    /// bytes. It is usable without Ghostty.app because the app ships the entry
    /// itself: `BundledTerminfo` resolves to `xterm-ghostty` when that compiled
    /// entry is present (and `spawn` points the child at it with TERMINFO_DIRS),
    /// and to `xterm-256color` when it is not, because a TERM naming an entry the
    /// database does not hold breaks every ncurses program.
    ///
    /// Set unconditionally rather than defaulted: inheriting Wietty's own TERM
    /// would tell the shell it is talking to whatever launched the app.
    static var terminalType: String { BundledTerminfo.term }

    /// What names the terminal itself, as against TERM, which names what it can
    /// draw. A program that adapts to its host reads this: iTerm2 answers
    /// `iTerm.app`, Ghostty.app answers `ghostty`, Apple's Terminal answers
    /// `Apple_Terminal`.
    ///
    /// Set for the same reason TERM is, and unconditionally for the same reason:
    /// left alone it names whatever launched Wietty, and an app opened from the
    /// Finder sets it to nothing at all. Either answer is wrong, and the wrong
    /// answer is worse than none, because the program acts on it.
    ///
    /// Unset is what the notifications this app posts were failing on. An agent
    /// choosing between the bell, OSC 9 and OSC 777 picks by this variable, finds
    /// nothing to match, and emits none of them, so a terminal that handles all
    /// three (`docs/notifications.md`) is never given the chance.
    static let programName = "Wietty"

    /// Spawns `command` on a fresh pty, or an interactive login shell when it is
    /// nil.
    ///
    /// Uses `forkpty`, not `posix_spawn`. This is not a style choice.
    /// `posix_spawn` cannot give the child a controlling terminal:
    /// `POSIX_SPAWN_SETSID` makes it a session leader, but acquiring the ctty
    /// needs `ioctl(TIOCSCTTY)` and there is no spawn file action for an ioctl.
    ///
    /// The observed failure is not a crash, which is what makes it worth a comment
    /// this long. A shell spawned that way reports `tty = ??`, `tpgid = 0`, cannot
    /// open `/dev/tty`, and has `monitor` off. `^C` then reaches nothing: the
    /// foreground command keeps running and the session wedges, echoing keystrokes
    /// while executing none of them. Nothing dies, so it reads as a hang rather
    /// than as a spawn bug. `forkpty` does the setsid and the `TIOCSCTTY` itself.
    ///
    /// `PTYProcessLauncher` can keep using `posix_spawn` because a logged managed
    /// process has no interactive job control to lose. The limitation is in
    /// `posix_spawn`'s own API rather than in the child: a program that issues
    /// `TIOCSCTTY` itself does acquire a ctty. Neither the login shell nor an
    /// arbitrary command can be relied on to do that, so this side does it.
    ///
    /// The size is applied to the pty as it is created, not after. A full screen
    /// program lays itself out from the size it finds at startup, so a terminal
    /// opened at the default 80x24 and resized a moment later shows a screen drawn
    /// for the wrong grid until something forces a redraw.
    static func spawn(command: String?,
                      directory: URL,
                      environment: [String: String],
                      size: TerminalSize,
                      shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        throws -> RawPTY {
        // Everything the child needs is built BEFORE the fork. Between fork and
        // exec only async-signal-safe calls are legal: the child inherits one
        // thread but every lock the parent held, so allocating, retaining, or
        // otherwise touching the Swift runtime there can deadlock outright. That
        // is why the argv and environment are C arrays already, and why the child
        // block below calls nothing but `signal`, `sigprocmask`, `chdir`, `execve`
        // and `_exit`, every one of which is async-signal-safe.
        //
        // `-l` for a login shell so PATH and shell setup match a terminal the user
        // opened themselves. With a command, `-i` is deliberately absent: an
        // interactive shell running `-c` prints job control notices the caller
        // never asked for. The working directory is `chdir`ed rather than prefixed
        // as `cd … &&`, so a command carrying its own quoting cannot be broken by
        // the prefix.
        let argv = command.map { [shell, "-l", "-c", $0] } ?? [shell, "-l", "-i"]
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        merged["TERM"] = Self.terminalType
        // Point the child at the bundled xterm-ghostty entry, prepended so every
        // other TERM it might look up still resolves. Nil (nothing bundled) leaves
        // any inherited value untouched, which pairs with the xterm-256color TERM.
        if let dirs = BundledTerminfo.terminfoDirs(inheriting: merged["TERMINFO_DIRS"]) {
            merged["TERMINFO_DIRS"] = dirs
        }
        // libghostty renders 24 bit colour, so say so the way Ghostty.app does.
        // Some programs read this rather than the terminfo `Tc`/`RGB` capability
        // to decide whether to emit truecolor, and would otherwise fall back to 256.
        merged["COLORTERM"] = "truecolor"
        merged["TERM_PROGRAM"] = Self.programName
        merged["TERM_PROGRAM_VERSION"] = AppVersion.current.description
        merged["PWD"] = directory.path
        let cEnv: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cShell = strdup(shell)
        let cDirectory = strdup(directory.path)
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cShell)
            free(cDirectory)
        }

        var window = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols),
                            ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &window)
        guard pid >= 0 else { throw RawPTYError.allocationFailed }
        if pid == 0 {
            // Child. `forkpty` has already made this a session leader with the pty
            // as its controlling terminal, which also makes it a process group
            // leader, so `terminate` can signal the group and reach the whole tree.
            //
            // Inherited signal state is reset before the exec, and it has to be. An
            // ignored disposition and a blocked signal mask both survive fork *and*
            // exec, so without this the shell inherits whatever the process that
            // launched Wietty happened to leave behind. That is measured rather
            // than theoretical: the `xcodebuild test` host blocks SIGHUP, SIGINT and
            // SIGQUIT, and a shell that inherits that mask can be neither
            // interrupted nor hung up, so `^C` reaches nothing and `terminate`
            // leaves the whole tree running. `signal` and `sigprocmask` are both
            // async-signal-safe, which is what makes them legal between fork and
            // exec; the loop is plain arithmetic for the same reason.
            var number: Int32 = 1
            while number < NSIG {
                signal(number, SIG_DFL)
                number += 1
            }
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            sigprocmask(SIG_SETMASK, &unblocked, nil)
            _ = chdir(cDirectory)
            execve(cShell, cArgv, cEnv)
            // Only reachable if execve failed. 127 is what a shell reports for a
            // command it could not run.
            _exit(127)
        }
        return RawPTY(masterFd: master, pid: pid)
    }

    /// Starts the byte stream and the reaper. Call once.
    ///
    /// One serial read source, so chunks are delivered in stream order. A caller
    /// that fanned these out onto unstructured `Task`s would corrupt the screen:
    /// two Tasks created in order can still run in either order.
    func startReading(onBytes: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) {
        let fd = masterFd
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "eu.kloosterman.wietty.pty-\(pid)"))
        // The read is the one use of the fd that does not go through `withMaster`,
        // and does not need to: dispatch runs the cancel handler, which is what
        // closes the master, only after the last event handler has returned, so
        // this read cannot overlap the close. Routing it through `withMaster`
        // would instead let a stalled read hold the descriptor open.
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            // EOF, or the master went away with the child. Either way the stream
            // is over; the reaper below reports the status.
            guard count > 0 else { source.cancel(); return }
            onBytes(Array(buffer[0..<count]))
        }
        source.setCancelHandler { [weak self] in self?.closeMaster() }
        lock.lock(); readSource = source; lock.unlock()
        source.resume()

        reap(reporting: onExit)
    }

    /// Waits on the child so it does not stay a zombie, and reports its status.
    /// At most one waiter ever runs.
    ///
    /// `terminate` needs this as much as `startReading` does. A terminal that is
    /// torn down before it ever started reading (an `open` that failed after the
    /// spawn, which is a path `GhosttyService` has two of) is signalled and then
    /// never waited on, so the child sits in the process table as a zombie for the
    /// life of the app. Nothing observes it and nothing recovers it.
    private func reap(reporting onExit: (@Sendable (Int32) -> Void)?) {
        lock.lock()
        let alreadyWaiting = waitStarted
        waitStarted = true
        lock.unlock()
        guard !alreadyWaiting else { return }
        let pid = self.pid
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            // Recorded before the status is reported, because the handler leads
            // straight to `terminate`, which must not signal a pid the kernel is
            // free to hand to something else.
            if let self { self.lock.lock(); self.childReaped = true; self.lock.unlock() }
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            onExit?(code)
        }
    }

    /// Runs `body` with the master fd, or does nothing and answers nil when the
    /// terminal is already gone.
    ///
    /// Every use of the descriptor goes through here, and checking a flag first
    /// and then making the syscall separately would not be equivalent. The EOF
    /// path closes the master from the read source's cancel handler without ever
    /// going through `terminate`, so `closed` stays false while the fd is already
    /// gone. Descriptors are recycled, which turns a keystroke arriving after the
    /// shell exited into a write into whatever this process opened next.
    ///
    /// The lock is released across the syscall rather than held across it, and the
    /// close is deferred to whichever call finishes last. Holding it would be
    /// shorter but can deadlock: a `write` to a pty whose child has stopped reading
    /// blocks once the buffer fills, and `terminate`, the one call that would
    /// release it by killing the child, would then be waiting on the same lock.
    @discardableResult
    private func withMaster<T>(_ body: (Int32) -> T) -> T? {
        lock.lock()
        guard !closed, !masterClosed else { lock.unlock(); return nil }
        inFlightUses += 1
        lock.unlock()
        defer { finishUsingMaster() }
        return body(masterFd)
    }

    /// Drops one use, and performs a close that was deferred while it was running.
    private func finishUsingMaster() {
        lock.lock()
        inFlightUses -= 1
        let closeNow = masterClosed && !fdClosed && inFlightUses == 0
        if closeNow { fdClosed = true }
        lock.unlock()
        if closeNow { close(masterFd) }
    }

    /// Hands `bytes` to the master, in the order they were handed over, without
    /// waiting for the child to read them. See `writes` for why this cannot happen on
    /// the caller's thread.
    ///
    /// Weakly, so a pty that has been released drops a write rather than being kept
    /// alive by one; there is nothing left to write to in that case anyway.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writes.async { [weak self] in self?.writeNow(bytes) }
    }

    /// Blocks until the writes already handed over have run.
    ///
    /// For tests, which is also why nothing in the app calls it: a write is
    /// asynchronous by design, and only a test asserting on what a write did or did
    /// not reach needs the barrier. Never call this from a thread a parked write has
    /// to be released by.
    func waitForPendingWrites() {
        writes.sync {}
    }

    private func writeNow(_ bytes: [UInt8]) {
        withMaster { fd in
            var offset = 0
            bytes.withUnsafeBytes { raw in
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    // A short write is normal on a full pty buffer. A failed one
                    // means the terminal is gone, and there is nothing to retry.
                    //
                    // Logged rather than raised. A keystroke that failed is not
                    // worth interrupting the user for, and a broken terminal fails
                    // every keystroke, so an alert each time would be worse than
                    // useless. But discarding it silently made a terminal that had
                    // stopped accepting input indistinguishable from one being
                    // typed into correctly, with nothing recorded anywhere. This is
                    // the same rule `TmuxStack.onSend` follows.
                    guard written > 0 else {
                        GhosttyLog.stack.error("""
                            write to terminal \(self.pid, privacy: .public) failed: \
                            errno \(errno, privacy: .public)
                            """)
                        return
                    }
                    offset += written
                }
            }
        }
    }

    /// Applies the surface's geometry. Idempotent, and safe to call on a pty
    /// whose child has already exited: the ioctl simply fails.
    func resize(to size: TerminalSize) {
        var window = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols),
                            ws_xpixel: 0, ws_ypixel: 0)
        withMaster { _ = ioctl($0, TIOCSWINSZ, &window) }
    }

    /// The name of the process group in the foreground of this terminal, or nil
    /// when it cannot be determined.
    ///
    /// Nil is an answer the caller must respect rather than treat as "no job".
    /// `ProjectStore.activate` types `claude` into a Claude row whose agent it
    /// believes is not running, so a failed query read as an absence submits that
    /// text into a live agent as a prompt. This is the polled counterpart of
    /// `FocusResult.jobKnown`.
    func foregroundJobName() -> String? {
        guard let group = withMaster({ tcgetpgrp($0) }), group > 0 else { return nil }
        // 2 * MAXCOMLEN is the size of `proc_bsdinfo.pbi_name`, which is the field
        // `proc_name` copies out, and it refuses anything smaller: handed a
        // MAXCOMLEN + 1 buffer it returns 0 with ENOMEM and no name at all, which
        // this reports as "unknown" for every process. The extra byte is room for
        // the terminator.
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        // proc_name takes a pid. The group leader is the process the shell put in
        // the foreground, which is the job the user is looking at.
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
        let text = String(cString: name)
        return text.isEmpty ? nil : text
    }

    /// Signals the whole group, stops reading, and collects the child.
    /// Idempotent.
    ///
    /// `SIGHUP` rather than `SIGKILL`: a hangup is what closing a terminal means,
    /// and it gives a shell the chance to run its own exit handling. The group is
    /// the target because the terminal may be running a pipeline.
    func terminate() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        let source = readSource
        readSource = nil
        let collected = childReaped
        lock.unlock()
        guard !alreadyClosed else { return }
        // Nothing to hang up once the child has been collected, and signalling
        // anyway would aim at a pid the kernel may already have handed to another
        // process. This is the common case on this substrate rather than an edge:
        // `GhosttyService.reap` terminates a terminal precisely because its child
        // just exited.
        if !collected { hangUp() }
        if let source {
            source.cancel()
        } else {
            closeMaster()
        }
        // After the signals, so a child that had not started is hung up before it
        // is waited on. A no-op when `startReading` already installed the waiter,
        // which is the usual case; this covers a terminal that never got that far.
        reap(reporting: nil)
    }

    /// Hangs up the terminal's whole process tree.
    private func hangUp() {
        killpg(pid, SIGHUP)
        // The group is the real target, and the child alone is signalled too
        // because for a short window there is no group to address. `forkpty` does
        // the `setsid` in the child, so between the parent returning from the fork
        // and the child reaching that call the child is still in Wietty's own
        // process group and `killpg(pid, …)` fails with ESRCH, signalling nobody.
        // Measured rather than theoretical: a `terminate` issued straight after
        // `spawn` missed 5 times out of 5, leaving a live login shell with no
        // terminal, and that is exactly the shape of `GhosttyService.open`'s
        // failure paths. In the same window the child has not exec'd yet and has no
        // descendants, so the pid is the whole tree; afterwards this is a second
        // SIGHUP to a process already being hung up, which changes nothing.
        kill(pid, SIGHUP)
    }

    /// Closes the master exactly once. Both the read source's cancel handler and
    /// `terminate` can reach here, and closing a descriptor twice can close one
    /// that has since been handed to something else entirely.
    ///
    /// The close waits for any syscall still using the fd: `withMaster` runs
    /// outside the lock, so this can arrive mid-write, and the last one out closes
    /// it. Nothing blocks here, because the caller is `terminate` or the read
    /// source, and neither may wait on a `write` that a stalled child is holding
    /// open. A write blocked at that moment is released by the SIGHUP `terminate`
    /// has already sent.
    private func closeMaster() {
        lock.lock()
        masterClosed = true
        let closeNow = !fdClosed && inFlightUses == 0
        if closeNow { fdClosed = true }
        lock.unlock()
        // Otherwise `finishUsingMaster` performs it when the last use returns.
        guard closeNow else { return }
        close(masterFd)
    }
}
