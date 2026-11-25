import Foundation

/// Reads one terminal's pty and hands every chunk to `onOutput`.
///
/// `onOutput` is what reaches `PaneStreamHub`, and through it every viewer of the
/// terminal: the app's own pane (by way of `LocalStreamServer` and the pane's bridge)
/// as much as a browser or an iPad. It runs on the pty's single read thread, once
/// per chunk, in the order the child wrote them, because terminal output delivered
/// out of order is corrupt on screen. A call that blocks holds the read back, which
/// is how a pane that is not reading holds back the child.
///
/// Input does not pass through here: the hub hands it to the writer
/// `GhosttyService` registers for the session, which writes the pty directly.
///
/// Reading starts at `start`, at most once, and never after `stop`. Both take the
/// same lock, so a `start` that races a `stop` either starts before it (and the
/// caller's `pty.terminate()` that follows `stop` ends the read) or does nothing:
/// a read started on a pty that has been terminated would watch a descriptor that
/// is already closed and may have been reused.
package final class TerminalRelay: @unchecked Sendable {
    private let pty: RawPTY
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    package init(pty: RawPTY, onOutput: @escaping @Sendable ([UInt8]) -> Void) {
        self.pty = pty
        self.onOutput = onOutput
    }

    /// Whether reading has started. For tests.
    package var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    /// Starts reading the pty, unless it has started already or the relay has been
    /// stopped. `onExit` is called once, with the child's wait status, when it exits.
    package func start(onExit: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !stopped else { return }
        started = true
        let onOutput = self.onOutput
        pty.startReading(onBytes: { bytes in onOutput(bytes) }, onExit: onExit)
    }

    /// Makes a later `start` do nothing. Idempotent. A read already running is
    /// ended by terminating the pty, which the owner does next.
    package func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
