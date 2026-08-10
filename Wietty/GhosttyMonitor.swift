import Foundation

/// Per session events on the libghostty substrate.
///
/// Three sources, and which is which is not arbitrary.
///
/// Titles and bells come from libghostty's runtime action callback
/// (`GHOSTTY_ACTION_SET_TITLE`, `GHOSTTY_ACTION_RING_BELL`), not from parsing the
/// byte stream. The stream is available, and `PaneStreamHub` already counts bells
/// in it, but titles would need OSC 0 and OSC 2 parsing that `OSCStringTracker`
/// does not do, and libghostty has already parsed both correctly.
///
/// Terminations come from `GhosttyService`, because the child exiting is what a
/// termination is on this substrate and the service is what reaps it. The surface
/// noticing its own child exited is a different event: that is the helper losing
/// its socket, which happens because the terminal ended rather than the other way
/// round.
///
/// Job names are not here at all. They are polled, through
/// `GhosttySubstrate.pollsJobs` and `JobPoll`, because nothing pushes them.
///
/// `@unchecked Sendable` plus a lock, the same shape `ITermMonitor` and
/// `TmuxMonitor` use, rather than `@MainActor` on the type: `SessionMonitoring`
/// refines `Sendable`, and neither a main actor isolated conformance nor an
/// isolated conformance to a `Sendable`-refining protocol is accepted by the
/// compiler. Unlike `TmuxMonitor`, delivery in `emit` is synchronous rather than
/// hopped through a `Task`: the only caller today is `ContentView.task`, already
/// on the main actor, and synchronous delivery leaves no window in which an
/// event queued before `stop()` can still land after it.
final class GhosttyMonitor: SessionMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@MainActor (MonitorEvent) -> Void)?

    @MainActor
    init(host: any TerminalSurfaceHosting) {
        host.onTitle = { [weak self] session, title in
            self?.emit([.title(sessionId: session, name: title)])
        }
        host.onBell = { [weak self] session in
            self?.emit([.bell(sessionId: session)])
        }
    }

    func start(onEvent: @escaping @MainActor (MonitorEvent) -> Void) {
        lock.lock()
        listener = onEvent
        lock.unlock()
    }

    func stop() {
        lock.lock()
        listener = nil
        lock.unlock()
    }

    /// Delivers events the monitor did not derive itself. Terminations arrive
    /// here from `GhosttyService`, so the app has one listener rather than two.
    @MainActor
    func emit(_ events: [MonitorEvent]) {
        lock.lock()
        let handler = listener
        lock.unlock()
        guard let handler else { return }
        for event in events { handler(event) }
    }
}
