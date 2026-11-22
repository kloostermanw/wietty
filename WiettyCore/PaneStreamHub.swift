import Foundation

/// Fans a terminal's output out to every viewer of it: the app's own pane, the
/// browser, and the iPad all consume the same byte stream, so a rendering fault is
/// fixed once.
///
/// Output is coalesced before delivery. A write arrives as soon as the child makes
/// it, and a shell echoing a typed line produces one per character, so forwarding
/// each one directly would put a WebSocket message on the wire for every
/// keystroke.
package final class PaneStreamHub: ScreenStreaming, @unchecked Sendable {
    private typealias Sink = @Sendable (RemoteMessage) -> Void

    /// Everything the hub holds for one session, behind that session's own lock.
    ///
    /// The lock is what makes a paint line up with the stream. Three things happen
    /// under it and nowhere else: a chunk is accepted for delivery and handed to
    /// `onIngest` (one step, so the two are always at the same byte offset when
    /// the lock is free), the accepted bytes are taken for delivery, and a paint
    /// is asked for. A viewer is registered under it too. So a paint taken while
    /// it is held describes exactly the bytes that have been taken, and whoever
    /// is registered at that moment receives exactly the bytes after them.
    ///
    /// Per session rather than one for the hub, because a parse runs under it: a
    /// terminal printing a build log must not hold up the bytes of the terminal
    /// next to it.
    private final class Stream {
        let lock = NSLock()
        var buffer: [UInt8] = []
        var chunker = UTF8Chunker()
        var tracker = OSCStringTracker()
        var viewers: [UUID: Sink] = [:]

        /// The accepted bytes as text, leaving a trailing incomplete UTF-8
        /// sequence in the chunker for the next take. Call with `lock` held.
        ///
        /// The chunker is never reset while the session lives, viewers or not.
        /// That is what keeps a character split across the moment of an attach
        /// whole: the screen model has not drawn it yet, so the paint does not
        /// hold it, and the chunker hands the new viewer all of its bytes in the
        /// next take rather than the second half alone.
        func takeText() -> String {
            guard !buffer.isEmpty else { return "" }
            let bytes = buffer
            buffer = []
            return chunker.take(bytes)
        }
    }

    /// Guards the registry below and the hooks. Held for a lookup and never while
    /// a session's own lock is taken, so there is no order between the two to get
    /// wrong.
    private let lock = NSLock()
    private var streams: [String: Stream] = [:]
    private var sessionForViewer: [UUID: String] = [:]
    /// The grid last seen for a session. libghostty reports a size on events that
    /// need not have moved it (a font metric change, a re-parent), so this is what
    /// keeps a repaint to the changes that really moved the grid.
    private var sizeForPane: [String: TerminalSize] = [:]
    private var timer: DispatchSourceTimer?
    /// Where everything that delivers to a viewer runs: the flush timer, an
    /// attach, the repaints and the endings.
    ///
    /// Serial, and shared by all of them, because each takes bytes from a session
    /// and then hands them to its viewers, and two of those running at once could
    /// take in one order and deliver in the other. Terminal output delivered out
    /// of order is corrupt on screen; one serial queue is what orders it. It is
    /// also off the writer's thread, so delivering never stalls the byte stream.
    private let delivery = DispatchQueue(label: "eu.kloosterman.wietty.pane-stream")

    /// Sends a command to the control client owning a pane. Wired in Task 12.
    package var onSend: (@Sendable (_ pane: String, _ text: String) -> Void)?
    /// Supplies the screen of a session as it is right now: what a viewer is sent
    /// on attach, and again when the grid moves.
    ///
    /// Called with the session's lock held, which is the point: no chunk can be
    /// accepted while it runs, so what it returns is the screen at exactly the
    /// byte offset the hub has taken for delivery. It must therefore answer from
    /// something `onIngest` keeps current, must not wait for another thread, and
    /// must not call back into the hub.
    package var onPaint: (@Sendable (_ pane: String) -> [RemoteMessage])?
    /// Feeds a session's screen model, with every chunk the hub accepts and in
    /// the same step that accepts it.
    ///
    /// Here rather than beside the hub in the service's fan out, because the hub
    /// is then the one place that knows the offset: "what the model has parsed"
    /// and "what has been accepted for delivery" cannot differ at any instant a
    /// paint could be taken. Fed beside the hub, a chunk could be delivered
    /// before the model had parsed it, and a viewer attaching in between got a
    /// paint without the chunk and a stream that had already passed it.
    ///
    /// Called on the writer's thread with the session's lock held, under the
    /// same rules as `onPaint`.
    package var onIngest: (@Sendable (_ session: String, _ bytes: [UInt8]) -> Void)?
    /// Which sessions are live, asked once per attach so a
    /// viewer is never registered for a session that cannot produce output. Left
    /// nil where there is nothing to ask, in which case an attach proceeds as it
    /// always did.
    ///
    /// Deliberately not folded into `onPaint`: an empty paint already means "no
    /// capture available right now", which a live session can return, so it
    /// cannot also mean "this session is gone".
    package var onSessionCensus: (@Sendable () -> SessionCensus)?
    /// Reports a genuine bell in a pane's output. Wired in Task 12, where the
    /// monitor turns it into a `.bell` event.
    package var onBell: (@Sendable (_ pane: String) -> Void)?

    /// Interval chosen so typing feels immediate while a burst of output still
    /// coalesces into one message.
    private static let flushInterval = DispatchTimeInterval.milliseconds(8)

    package init(startTimer: Bool = false) {
        if startTimer { startFlushTimer() }
    }

    deinit { timer?.cancel() }

    private func startFlushTimer() {
        let source = DispatchSource.makeTimerSource(queue: delivery)
        source.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        source.setEventHandler { [weak self] in self?.flushNow(sessions: nil) }
        source.resume()
        timer = source
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
    package func endViewers(ofSession session: String) {
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
        lock.lock()
        let ending = panes.compactMap { streams.removeValue(forKey: $0) }
        sessionForViewer = sessionForViewer.filter { !panes.contains($0.value) }
        for pane in panes { sizeForPane[pane] = nil }
        lock.unlock()
        for stream in ending {
            // Everything already accepted, taken in the same step that empties
            // the viewers and delivered ahead of the `ended`, on this queue, so
            // it is ordered after every earlier flush rather than racing one.
            stream.lock.lock()
            let text = stream.takeText()
            let sinks = Array(stream.viewers.values)
            stream.viewers = [:]
            stream.lock.unlock()
            for sink in sinks {
                if !text.isEmpty { sink(.data(text)) }
                sink(.ended)
            }
        }
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
    package static func isStreamable(session: String, census: SessionCensus) -> Bool {
        guard !session.isEmpty else { return false }
        switch census {
        case let .sessions(live): return live.contains(session)
        case .noServer: return false
        case .unknown: return true
        }
    }

    /// Paints a viewer and registers it, as one step.
    ///
    /// The step is: take what has been accepted for the session and not yet
    /// delivered, ask for the paint, register the viewer. All three under the
    /// session's lock, so no chunk can arrive between them. The bytes taken go to
    /// the viewers that were already there and not to the new one, whose paint
    /// already shows them. Everything accepted afterwards goes to all of them.
    /// The new viewer therefore sees every byte exactly once: up to the paint in
    /// the paint, and after it in the stream.
    ///
    /// Each half used to be wrong in its own way. Painting first and registering
    /// second left whatever sat in the buffer to be flushed to the new viewer on
    /// top of a paint that already contained it, so plain output (a build log,
    /// `cat`) showed lines twice.
    ///
    /// Runs on `delivery`, synchronously, because the paint has to reach the
    /// viewer before any stream bytes do, and that queue is what orders the two.
    /// So it must not be called from a viewer's own sink, which runs there.
    @discardableResult
    package func attach(session: String, onMessage: @escaping @Sendable (RemoteMessage) -> Void) -> UUID {
        let id = UUID()
        delivery.sync { attachNow(id: id, session: session, sink: onMessage) }
        return id
    }

    private func attachNow(id: UUID, session: String, sink: @escaping Sink) {
        lock.lock()
        let paint = onPaint
        let census = onSessionCensus
        lock.unlock()
        // A session id naming no live terminal can never produce a byte, and
        // nothing else on this socket would ever say so. Ending the viewer here is
        // what separates a session that is gone from one that is merely idle.
        // Without it the socket upgrades and then stays silent forever, and a
        // client has no way to tell which it got.
        //
        // Reachable from the sidebar rather than only by a hand-built request: a
        // terminal row survives its terminal so it can be restarted, and a row
        // that was never opened carries no session id at all.
        if let census, !Self.isStreamable(session: session, census: census()) {
            sink(.ended)
            return
        }
        lock.lock()
        let stream = streams[session] ?? Stream()
        streams[session] = stream
        sessionForViewer[id] = session
        lock.unlock()

        stream.lock.lock()
        let outstanding = stream.takeText()
        let alreadyWatching = Array(stream.viewers.values)
        let painted = paint?(session) ?? []
        stream.viewers[id] = sink
        stream.lock.unlock()

        if !outstanding.isEmpty { for watcher in alreadyWatching { watcher(.data(outstanding)) } }
        for message in painted { sink(message) }
    }

    /// Unregisters a viewer. The session's stream state stays: its chunker and
    /// its bell tracker describe the byte stream, not who is watching it.
    package func detach(connectionId: UUID) {
        lock.lock()
        let stream = sessionForViewer.removeValue(forKey: connectionId).flatMap { streams[$0] }
        lock.unlock()
        guard let stream else { return }
        stream.lock.lock()
        stream.viewers[connectionId] = nil
        stream.lock.unlock()
    }

    package func send(session: String, text: String) {
        lock.lock()
        let handler = onSend
        lock.unlock()
        handler?(session, text)
    }

    /// Drops the viewers and their buffers, and stops the flush timer. The sizes
    /// survive: a session id stays valid across a stop and start, and clearing them
    /// would make the next `noteSize` look like a change that never happened.
    package func stop() {
        lock.lock()
        streams = [:]
        sessionForViewer = [:]
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
    /// remote, and it is what lets the screen model be fed at exactly the offset
    /// the viewers are served from: see `onIngest`.
    ///
    /// Callers must call this in stream order and from one thread per session.
    /// Terminal output delivered out of order is corrupt on screen, and this
    /// method does not reorder anything.
    package func write(session: String, bytes: [UInt8]) {
        lock.lock()
        let stream = streams[session] ?? Stream()
        streams[session] = stream
        let ingest = onIngest
        let bell = onBell
        lock.unlock()

        stream.lock.lock()
        stream.buffer.append(contentsOf: bytes)
        ingest?(session, bytes)
        let bells = stream.tracker.bells(in: bytes)
        stream.lock.unlock()
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
    package func noteSize(session: String, _ size: TerminalSize) {
        lock.lock()
        let changed = sizeForPane[session] != size
        sizeForPane[session] = size
        lock.unlock()
        guard changed else { return }
        repaint(pane: session, fallback: [.resize(cols: size.cols, rows: size.rows)])
    }

    /// Re-sends a pane's whole screen to its viewers, for the cases where the
    /// stream they hold has become unreliable. Falls back to `fallback` when
    /// there is no paint source or the paint came back empty.
    ///
    /// Runs on `delivery` rather than on the caller's thread; see the queue's own
    /// comment for the ordering that depends on it.
    ///
    /// The same join an attach makes, for the same reason. What was accepted
    /// before the paint is taken under the session's lock and delivered ahead of
    /// it, the paint is taken under that same lock, and everything accepted
    /// afterwards follows it. So a repaint neither repeats a byte nor loses one.
    /// The bytes ahead of the paint used to be dropped instead, which was only
    /// harmless while the paint was an approximation nobody lined a stream up
    /// against: a line that scrolled off the screen inside those bytes never
    /// reached the viewer's scrollback.
    private func repaint(pane: String, fallback: [RemoteMessage]) {
        delivery.async { [weak self] in self?.repaintNow(pane: pane, fallback: fallback) }
    }

    private func repaintNow(pane: String, fallback: [RemoteMessage]) {
        lock.lock()
        let paint = onPaint
        let stream = streams[pane]
        lock.unlock()
        guard let stream else { return }

        stream.lock.lock()
        let sinks = Array(stream.viewers.values)
        // Nothing is delivered without a viewer, so there is nothing to take and
        // nothing to paint either.
        guard !sinks.isEmpty else { stream.lock.unlock(); return }
        let outstanding = stream.takeText()
        let painted = paint?(pane) ?? []
        stream.lock.unlock()

        if !outstanding.isEmpty { for sink in sinks { sink(.data(outstanding)) } }
        guard !painted.isEmpty else {
            // An empty paint is a paint that could not be built, not an empty
            // screen. The fallback carries a resize at best, so the viewer keeps
            // a screen laid out for the old grid until the stream redraws it.
            // Worth recording: it is indistinguishable from a working idle
            // terminal.
            GhosttyLog.stack.error("""
                could not paint session \(pane, privacy: .public) for a repaint; \
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
    package func waitForPendingDeliveries() {
        delivery.sync {}
    }

    /// Emits one `.data` per session holding accepted output, dropping any
    /// trailing incomplete UTF-8 sequence into the next flush.
    ///
    /// On `delivery`, like every other delivery, so a caller's flush and the
    /// timer's cannot take in one order and deliver in the other. Synchronous, so
    /// a test can assert on what a viewer received as soon as it returns. Not to
    /// be called from a viewer's sink, which already runs there.
    package func flush() {
        delivery.sync { flushNow(sessions: nil) }
    }

    /// - Parameter sessions: which sessions to flush, or nil for all of them.
    private func flushNow(sessions: Set<String>?) {
        lock.lock()
        let flushing = streams.filter { sessions?.contains($0.key) ?? true }.map(\.value)
        lock.unlock()
        for stream in flushing {
            stream.lock.lock()
            let text = stream.takeText()
            let sinks = Array(stream.viewers.values)
            stream.lock.unlock()
            guard !text.isEmpty else { continue }
            for sink in sinks { sink(.data(text)) }
        }
    }
}
