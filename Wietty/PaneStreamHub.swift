import Foundation

/// Fans a terminal's output out to every viewer of it: the app's own pane, the
/// browser, and the iPad all consume the same byte stream, so a rendering fault is
/// fixed once.
///
/// Output is coalesced before delivery. A write arrives as soon as the child makes
/// it, and a shell echoing a typed line produces one per character, so forwarding
/// each one directly would put a WebSocket message on the wire for every
/// keystroke.
final class PaneStreamHub: ScreenStreaming, @unchecked Sendable {
    private struct Viewer {
        let pane: String
        let sink: @Sendable (RemoteMessage) -> Void
    }

    private let lock = NSLock()
    private var viewers: [UUID: Viewer] = [:]
    private var buffers: [String: [UInt8]] = [:]
    private var chunkers: [String: UTF8Chunker] = [:]
    private var trackers: [String: OSCStringTracker] = [:]
    /// The grid last seen for a session. libghostty reports a size on events that
    /// need not have moved it (a font metric change, a re-parent), so this is what
    /// keeps a repaint to the changes that really moved the grid.
    private var sizeForPane: [String: TerminalSize] = [:]
    private var timer: DispatchSourceTimer?
    /// Where everything that delivers to a viewer runs: the flush timer and the
    /// repaints.
    ///
    /// Serial, and shared by both, because a repaint has to be ordered against the
    /// flush that carries the bytes produced while it ran. Out of order, the paint
    /// lands after newer output and erases it; one serial queue is what orders
    /// them. It is also off the writer's thread, so building a paint never stalls
    /// the byte stream it is built from.
    private let delivery = DispatchQueue(label: "eu.kloosterman.wietty.pane-stream")

    /// Sends a command to the control client owning a pane. Wired in Task 12.
    var onSend: (@Sendable (_ pane: String, _ text: String) -> Void)?
    /// Supplies the initial screen for a pane. Wired in Task 12.
    var onPaint: (@Sendable (_ pane: String) -> [RemoteMessage])?
    /// Which sessions are live, asked once per attach so a
    /// viewer is never registered for a session that cannot produce output. Left
    /// nil where there is nothing to ask, in which case an attach proceeds as it
    /// always did.
    ///
    /// Deliberately not folded into `onPaint`: an empty paint already means "no
    /// capture available right now", which a live session can return, so it
    /// cannot also mean "this session is gone".
    var onSessionCensus: (@Sendable () -> SessionCensus)?
    /// Reports a genuine bell in a pane's output. Wired in Task 12, where the
    /// monitor turns it into a `.bell` event.
    var onBell: (@Sendable (_ pane: String) -> Void)?

    /// Interval chosen so typing feels immediate while a burst of output still
    /// coalesces into one message.
    private static let flushInterval = DispatchTimeInterval.milliseconds(8)

    init(startTimer: Bool = false) {
        if startTimer { startFlushTimer() }
    }

    deinit { timer?.cancel() }

    private func startFlushTimer() {
        let source = DispatchSource.makeTimerSource(queue: delivery)
        source.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume()
        timer = source
    }

    /// Builds the paint sent to a viewer on attach: clear, home, the visible
    /// rows, then the cursor. A session sitting idle produces no output, so a
    /// viewer that only subscribed would face a blank screen until something
    /// happened to change it.
    static func paintMessages(rows: [String], cursorX: Int, cursorY: Int,
                              cols: Int, rows rowCount: Int) -> [RemoteMessage] {
        var vt = "\u{1B}[2J\u{1B}[H"
        vt += rows.joined(separator: "\r\n")
        vt += "\u{1B}[\(cursorY + 1);\(cursorX + 1)H"
        return [.resize(cols: cols, rows: rowCount), .data(vt)]
    }

    /// Ends every viewer of one session. Called when that session's terminal has
    /// stopped producing bytes for good: its child exited, or the row was closed.
    ///
    /// There is no workspace object to key this on and no notification from
    /// anywhere else: the terminal is a PTY in this process, so the service that
    /// reaps it is the one thing that knows. Without this a browser or an iPad watching a terminal
    /// whose command exited went silent forever, which is exactly the state the
    /// census on attach exists to prevent for a viewer arriving later.
    ///
    /// Safe from the main actor, which is where that service runs: the state here is
    /// lock guarded, the delivery is handed to `delivery`, and nothing here reaches
    /// back. The direction matters and is the same one the census and the paint
    /// follow: the main actor reaches into this lock guarded type, never the other
    /// way round.
    ///
    /// Asynchronous, like a repaint, so a test that asserts on what a viewer received
    /// needs `waitForPendingDeliveries()`.
    func endViewers(ofSession session: String) {
        endViewers(ofSessions: [session])
    }

    /// Runs on `delivery`, and has to, for the same reason a repaint does: the last
    /// bytes a session produced must reach its viewers BEFORE the ending, and only
    /// this queue orders that against the flush timer that carries them.
    ///
    /// The bytes were dropped outright before, which is not an edge case: a command
    /// that prints and exits does both inside one 8 ms flush interval, so a browser
    /// watching `echo` saw the session end and never saw what it printed.
    private func endViewers(ofSessions panes: Set<String>) {
        delivery.async { [weak self] in self?.endViewersNow(panes) }
    }

    private func endViewersNow(_ panes: Set<String>) {
        // Everything already buffered, first and on this queue, so it is ordered
        // ahead of the `ended` below rather than racing it.
        flush(sessions: panes)
        lock.lock()
        let ended = viewers.filter { panes.contains($0.value.pane) }
        for id in ended.keys { viewers.removeValue(forKey: id) }
        for pane in panes {
            buffers[pane] = nil
            chunkers[pane] = nil
            trackers[pane] = nil
            sizeForPane[pane] = nil
        }
        let sinks = ended.values.map(\.sink)
        lock.unlock()
        for sink in sinks { sink(.ended) }
    }

    /// Whether a session id can still be streamed at all, given what the server
    /// says it holds.
    ///
    /// The rule: act on a confirmed absence, never on a query that merely failed.
    /// A transient failure must not end a viewer watching a terminal that is fine.
    ///
    /// An empty id is not attachable and is not worth a census: it is what a
    /// terminal row that was configured but never opened carries, and asking about
    /// it would resolve it to something nobody asked for.
    static func isStreamable(session: String, census: SessionCensus) -> Bool {
        guard !session.isEmpty else { return false }
        switch census {
        case let .sessions(live): return live.contains(session)
        case .noServer: return false
        case .unknown: return true
        }
    }

    @discardableResult
    func attach(session: String, onMessage: @escaping @Sendable (RemoteMessage) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let paint = onPaint
        let census = onSessionCensus
        lock.unlock()
        // A session id naming no live pane can never produce a byte, and nothing
        // else on this socket would ever say so: `%window-close` fires when a pane
        // dies, not when a viewer arrives after it already has. Ending the viewer
        // here is what separates a session that is gone from one that is merely
        // idle. Without it the socket upgrades and then stays silent forever, and
        // a client has no way to tell which it got.
        //
        // Reachable from the sidebar rather than only by a hand-built request: a
        // terminal row survives its pane so it can be restarted, and a row that
        // was never opened carries no session id at all.
        if let census, !Self.isStreamable(session: session, census: census()) {
            onMessage(.ended)
            return id
        }
        // Paint BEFORE registering. Registering first lets the flush timer deliver
        // live output that the paint's clear-screen then erases.
        for message in paint?(session) ?? [] { onMessage(message) }
        lock.lock()
        viewers[id] = Viewer(pane: session, sink: onMessage)
        if chunkers[session] == nil { chunkers[session] = UTF8Chunker() }
        lock.unlock()
        return id
    }

    func detach(connectionId: UUID) {
        lock.lock()
        guard let viewer = viewers.removeValue(forKey: connectionId) else { lock.unlock(); return }
        let paneGone = !viewers.values.contains { $0.pane == viewer.pane }
        if paneGone {
            buffers[viewer.pane] = nil
            chunkers[viewer.pane] = nil
            trackers[viewer.pane] = nil
        }
        lock.unlock()
    }

    func send(session: String, text: String) {
        lock.lock()
        let handler = onSend
        lock.unlock()
        handler?(session, text)
    }

    /// Drops the viewers and their buffers, and stops the flush timer. The sizes
    /// survive: a session id stays valid across a stop and start, and clearing them
    /// would make the next `noteSize` look like a change that never happened.
    func stop() {
        lock.lock()
        viewers = [:]
        buffers = [:]
        chunkers = [:]
        trackers = [:]
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Takes one terminal's raw output.
    ///
    /// The single ingestion point, called by `TerminalRelay` from the read source on
    /// its PTY master. One entry point is what keeps one coalescing policy, one
    /// UTF-8 boundary policy, and one bell detector for every viewer, local and
    /// remote.
    ///
    /// Callers must call this in stream order and from one thread per session.
    /// Terminal output delivered out of order is corrupt on screen, and this
    /// method does not reorder anything.
    func write(session: String, bytes: [UInt8]) {
        lock.lock()
        buffers[session, default: []].append(contentsOf: bytes)
        var tracker = trackers[session] ?? OSCStringTracker()
        let bells = tracker.bells(in: bytes)
        trackers[session] = tracker
        let bell = onBell
        lock.unlock()
        // One call per counted bell: a program ringing twice in one write should
        // be reported twice, and an OSC terminator not at all.
        for _ in 0..<bells { bell?(session) }
    }

    /// A session's grid changed, so tell its viewers and repaint them.
    ///
    /// A viewer is told its size in the paint it receives on attach, and nothing
    /// else on the socket ever mentions it, so a grid that moves afterwards leaves
    /// every viewer rendering reflowed bytes against the old one. The repaint
    /// carries the new size in its leading `.resize`, so one message stream fixes
    /// both the grid and the content the reflow rewrote.
    ///
    /// Deduped on the last size seen, because both callers can report a size that
    /// did not change: libghostty reports a grid on events (a font metric change, a
    /// re-parent) that need not have moved it.
    ///
    /// Called from the main actor. Safe: the state is lock guarded and the delivery
    /// itself is handed to `delivery`.
    func noteSize(session: String, _ size: TerminalSize) {
        lock.lock()
        let changed = sizeForPane[session] != size
        sizeForPane[session] = size
        lock.unlock()
        guard changed else { return }
        repaint(pane: session, fallback: [.resize(cols: size.cols, rows: size.rows)])
    }

    /// Re-sends a pane's whole screen to its viewers, for the cases where the
    /// stream they hold has become unreliable. Falls back to `fallback` when
    /// there is no paint source or the capture failed.
    ///
    /// Runs on `delivery` rather than on the caller's thread; see the queue's own
    /// comment for the ordering that depends on it.
    ///
    /// Buffered bytes are dropped before the paint is built rather than after it.
    /// The flush timer runs every 8 ms, so bytes produced while it runs will be
    /// delivered after the paint no matter when the buffer
    /// is cleared; clearing afterwards would silently discard them instead.
    /// Re-showing a few bytes the paint already contains is self correcting, and
    /// losing them is not.
    private func repaint(pane: String, fallback: [RemoteMessage]) {
        delivery.async { [weak self] in self?.repaintNow(pane: pane, fallback: fallback) }
    }

    private func repaintNow(pane: String, fallback: [RemoteMessage]) {
        lock.lock()
        let paint = onPaint
        let sinks = viewers.values.filter { $0.pane == pane }.map(\.sink)
        // Nothing is delivered without a viewer, so nothing needs discarding
        // either. Clearing regardless created a chunker entry for a pane with no
        // viewers on every layout change, which nothing then removed.
        guard !sinks.isEmpty else { lock.unlock(); return }
        buffers[pane] = nil
        chunkers[pane] = UTF8Chunker()
        lock.unlock()
        let painted = paint?(pane) ?? []
        guard !painted.isEmpty else {
            // An empty paint is a failed capture, not an empty screen: `paint`
            // returns nothing when `capture-pane` failed, when the pane is gone,
            // and when the geometry line was unreadable. The fallback carries a
            // resize at best and is empty on the `%continue` path, so the viewer
            // silently keeps a screen that is stale by an unknown amount. Worth
            // recording: it is indistinguishable from a working idle terminal.
            GhosttyLog.stack.error("""
                could not capture pane \(pane, privacy: .public) for a repaint; \
                \(sinks.count) viewer(s) keep a stale screen
                """)
            for sink in sinks { for message in fallback { sink(message) } }
            return
        }
        for sink in sinks { for message in painted { sink(message) } }
    }

    /// Blocks until the delivery work already queued has run.
    ///
    /// A repaint is asynchronous by design, so a caller that triggers one and
    /// then wants to observe its result needs the barrier. Tests drive `ingest`
    /// from the test thread and assert on what a viewer received; in the app the
    /// flush timer gets the same ordering for free by running on this queue.
    func waitForPendingDeliveries() {
        delivery.sync {}
    }

    /// Emits one `.data` per pane holding buffered output, dropping any trailing
    /// incomplete UTF-8 sequence into the next flush.
    func flush() {
        flush(sessions: nil)
    }

    /// - Parameter sessions: which panes to flush, or nil for all of them. A subset
    ///   is what an ending needs: it has to deliver that session's outstanding bytes
    ///   without touching anyone else's, and it runs on this queue so its flush and
    ///   the timer's cannot interleave.
    private func flush(sessions: Set<String>?) {
        lock.lock()
        var deliveries: [(sink: @Sendable (RemoteMessage) -> Void, text: String)] = []
        for (pane, bytes) in buffers
        where !bytes.isEmpty && (sessions?.contains(pane) ?? true) {
            buffers[pane] = []
            var chunker = chunkers[pane] ?? UTF8Chunker()
            let text = chunker.take(bytes)
            chunkers[pane] = chunker
            guard !text.isEmpty else { continue }
            for viewer in viewers.values where viewer.pane == pane {
                deliveries.append((viewer.sink, text))
            }
        }
        lock.unlock()
        for delivery in deliveries { delivery.sink(.data(delivery.text)) }
    }
}
