import Foundation
import WiettyShared

/// Fans a terminal's output out to every viewer of it: the browser, the iPad and
/// another Mac's remote pane all consume the same byte stream, so a rendering fault
/// is fixed once.
///
/// The bytes are the child's own, exactly: nothing is decoded, replaced or held
/// back. A viewer's terminal decodes them, as it would from any pty.
///
/// Output is coalesced before delivery. A write arrives as soon as the child makes
/// it, and a shell echoing a typed line produces one per character, so forwarding
/// each one directly would put a message on the wire for every keystroke. A write
/// into a quiet session that has a viewer is the exception: it goes out at once, so
/// the echo of a keystroke does not wait for the timer.
package final class PaneStreamHub: ScreenStreaming, @unchecked Sendable {
    private typealias Sink = @Sendable (StreamMessage) -> Void

    private struct Viewer {
        let sink: Sink
        let resize: ResizeMode
    }

    /// Everything the hub holds for one session, behind that session's own lock.
    ///
    /// The lock is what makes a snapshot or a repaint line up with the stream.
    /// Three things happen under it and nowhere else: a chunk is accepted for
    /// delivery and handed to `onIngest` (one step, so the two are always at the
    /// same byte offset when the lock is free), the accepted bytes are taken for
    /// delivery, and a frame is asked for. A viewer is registered under it too.
    /// So a frame taken while it is held describes exactly the bytes that have
    /// been taken, and whoever is registered at that moment receives exactly the
    /// bytes after them.
    ///
    /// Nothing is delivered under it: what is taken is handed to the viewers after
    /// it is released, on `delivery`, which is what orders deliveries.
    ///
    /// Per session rather than one for the hub, because a parse runs under it: a
    /// terminal printing a build log must not hold up the bytes of the terminal
    /// next to it.
    ///
    /// `@unchecked Sendable` because every field is read and written under `lock`.
    private final class Stream: @unchecked Sendable {
        let lock = NSLock()
        var buffer: [UInt8] = []
        var tracker = OSCStringTracker()
        var viewers: [UUID: Viewer] = [:]
        /// The viewers whose last snapshot was taken on the alternate screen, and
        /// so hold an empty primary screen underneath it.
        var onAlternateScreen: Set<UUID> = []
        /// The end of the accepted stream when it is the start of a UTF-8
        /// character whose remaining bytes have not arrived: at most three bytes.
        /// See `incompleteCharacter(after:_:)`.
        var pendingCharacter: [UInt8] = []
        /// When bytes were last taken from `buffer` by a flush, in uptime
        /// nanoseconds. Zero for never.
        var lastFlush: UInt64 = 0
        /// How many writes the quiet rule has sent straight to `delivery`. Read
        /// only by the tests, through `quietFlushes(session:)`.
        var quietFlushes = 0

        /// The accepted bytes, leaving the buffer empty. A swap, not a copy: this
        /// runs under the lock, and the lock is the terminal's write path.
        func take() -> [UInt8] {
            let bytes = buffer
            buffer = []
            return bytes
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
    /// keeps a resize to the changes that really moved the grid.
    private var sizeForPane: [String: TerminalSize] = [:]
    private var timer: DispatchSourceTimer?
    /// Where everything that delivers to a viewer runs: the flush timer, a quiet
    /// flush, an attach, a resync, a resize and an ending.
    ///
    /// Serial, and shared by all of them, because each takes bytes from a session
    /// and then hands them to its viewers, and two of those running at once could
    /// take in one order and deliver in the other. Terminal output delivered out
    /// of order is corrupt on screen; one serial queue is what orders it. It is
    /// also off the writer's thread, so delivering never stalls the byte stream.
    private let delivery = DispatchQueue(label: "eu.kloosterman.wietty.pane-stream")

    /// Hands a remote viewer's input to the session's terminal. Called on the
    /// thread `send` is called on, which is the point: input must not wait for the
    /// main actor, and the pty's writer queues it in order on its own.
    package var onInput: (@Sendable (_ session: String, _ bytes: [UInt8]) -> Void)?
    /// Supplies what a viewer is sent on attach and on a resync: the grid, the
    /// history and the screen, as VT for behind `TerminalPaint.hardReset`, and
    /// whether that leaves the viewer on the alternate screen. Nil when no
    /// snapshot can be built.
    ///
    /// Called with the session's lock held, which is the point: no chunk can be
    /// accepted while it runs, so what it returns is the terminal at exactly the
    /// byte offset the hub has taken for delivery. It must therefore answer from
    /// something `onIngest` keeps current, must not wait for another thread, and
    /// must not call back into the hub.
    package var onSnapshot: (@Sendable (_ session: String) -> TerminalSnapshotFrame?)?
    /// Supplies the visible screen after the grid changed, for a viewer that asked
    /// for repaints: the grid and VT for behind `TerminalPaint.reset`. Nil when no
    /// frame can be built. Under the same rules as `onSnapshot`.
    package var onRepaint: (@Sendable (_ session: String) -> (size: TerminalSize, frame: [UInt8])?)?
    /// Whether a session's terminal is on the alternate screen now. Asked after a
    /// write, under the session's lock, and only while a viewer is waiting for the
    /// terminal to leave it. Under the same rules as `onSnapshot`.
    package var onAlternateScreen: (@Sendable (_ session: String) -> Bool)?
    /// Feeds a session's screen model, with every chunk the hub accepts and in
    /// the same step that accepts it.
    ///
    /// Here rather than beside the hub in the service's fan out, because the hub
    /// is then the one place that knows the offset: "what the model has parsed"
    /// and "what has been accepted for delivery" cannot differ at any instant a
    /// frame could be taken. Fed beside the hub, a chunk could be delivered
    /// before the model had parsed it, and a viewer attaching in between got a
    /// snapshot without the chunk and a stream that had already passed it.
    ///
    /// Called on the writer's thread with the session's lock held, under the
    /// same rules as `onSnapshot`.
    package var onIngest: (@Sendable (_ session: String, _ bytes: [UInt8]) -> Void)?
    /// Which sessions are live, asked once per attach so a
    /// viewer is never registered for a session that cannot produce output. Left
    /// nil where there is nothing to ask, in which case an attach proceeds as it
    /// always did.
    ///
    /// Deliberately not folded into `onSnapshot`: a snapshot that cannot be built
    /// already has its own meaning, which a live session can produce, so it
    /// cannot also mean "this session is gone".
    package var onSessionCensus: (@Sendable () -> SessionCensus)?
    /// Reports a genuine bell in a pane's output. Unwired in the app, where the
    /// surface reports the bell; while it is nil the hub does not look for bells.
    package var onBell: (@Sendable (_ pane: String) -> Void)?

    /// Interval chosen so typing feels immediate while a burst of output still
    /// coalesces into one message.
    private static let flushInterval = DispatchTimeInterval.milliseconds(8)
    /// The same interval, for the quiet rule: a write into an empty buffer of a session
    /// that has a viewer goes out at once when the last flush is older than this.
    private static let quietNanoseconds: UInt64 = 8_000_000

    package init(startTimer: Bool = false) {
        if startTimer { startFlushTimer() }
    }

    deinit { timer?.cancel() }

    private func startFlushTimer() {
        let source = DispatchSource.makeTimerSource(queue: delivery)
        source.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        source.setEventHandler { [weak self] in self?.flushNow(waiting: false) }
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
    /// back. The direction matters and is the same one the census and the frames
    /// follow: the main actor reaches into this lock guarded type, never the other
    /// way round.
    ///
    /// Asynchronous, like a resize, so a test that asserts on what a viewer received
    /// needs `waitForPendingDeliveries()`.
    package func endViewers(ofSession session: String) {
        endViewers(ofSessions: [session])
    }

    /// Runs on `delivery`, and has to, for the same reason a resize does: the last
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
            let bytes = stream.take()
            let sinks = stream.viewers.values.map(\.sink)
            stream.viewers = [:]
            stream.onAlternateScreen = []
            stream.lock.unlock()
            for sink in sinks {
                if !bytes.isEmpty { sink(.data(bytes)) }
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

    /// Sends a viewer the grid and a snapshot and registers it, as one step.
    ///
    /// The step is: take what has been accepted for the session and not yet
    /// delivered, ask for the snapshot, register the viewer. All three under the
    /// session's lock, so no chunk can arrive between them. The bytes taken go to
    /// the viewers that were already there and not to the new one, whose snapshot
    /// already holds them. Everything accepted afterwards goes to all of them.
    /// The new viewer therefore sees every byte exactly once: up to the snapshot in
    /// the snapshot, and after it in the stream. The server's `hello` is not the
    /// hub's business; whoever owns the transport sends it before calling this.
    ///
    /// **Where `onMessage` runs.** Always on the hub's delivery queue, and never
    /// with a lock of the hub's held, so it may call `resync` and `detach`. It must
    /// not call `attach` or `flush`, which wait for that queue and would wait for
    /// themselves. It is called for one viewer at a time, in delivery order, and a
    /// slow `onMessage` holds up every viewer of every session: it should hand the
    /// message on (a `ViewerQueue`) rather than write a socket.
    ///
    /// Runs on `delivery`, synchronously, because the snapshot has to reach the
    /// viewer before any stream bytes do, and that queue is what orders the two.
    @discardableResult
    package func attach(session: String, resize: ResizeMode,
                        onMessage: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        let id = UUID()
        delivery.sync { attachNow(id: id, session: session, viewer: Viewer(sink: onMessage, resize: resize)) }
        return id
    }

    private func attachNow(id: UUID, session: String, viewer: Viewer) {
        lock.lock()
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
            viewer.sink(.ended)
            return
        }
        lock.lock()
        let stream = streams[session] ?? Stream()
        streams[session] = stream
        sessionForViewer[id] = session
        lock.unlock()

        guard let join = join(stream, session: session, viewer: id, registering: viewer) else { return }
        join.deliver()
        if !join.snapshotBuilt, join.snapshotAsked {
            GhosttyLog.stack.error("""
                no snapshot of session \(session, privacy: .public) for a viewer attaching; \
                it starts from the stream alone
                """)
        }
    }

    /// What one join took under the session's lock, delivered after it.
    private struct Join {
        /// The bytes accepted before the snapshot, and who gets them: the other
        /// viewers when there is a snapshot, since it holds these bytes, and every
        /// viewer of a resync that has none.
        let outstanding: [UInt8]
        let outstandingTo: [Sink]
        let viewer: Sink
        /// A `resize` and a `snapshot`. When no snapshot was built: for a new
        /// viewer, the `resize` alone if the grid is known, and otherwise nothing.
        let messages: [StreamMessage]
        /// Whether `messages` holds a snapshot.
        let snapshotBuilt: Bool
        /// Whether there was a hook to ask, so no snapshot means it failed.
        let snapshotAsked: Bool

        func deliver() {
            if !outstanding.isEmpty { for sink in outstandingTo { sink(.data(outstanding)) } }
            for message in messages { viewer(message) }
        }
    }

    /// The join an attach and a resync make, under the session's lock: register
    /// the viewer when it is new, take the outstanding bytes, take the snapshot.
    /// Call on `delivery`. Nil when the viewer is not there to join.
    private func join(_ stream: Stream, session: String, viewer id: UUID,
                      registering new: Viewer? = nil) -> Join? {
        lock.lock()
        let hook = onSnapshot
        let grid = sizeForPane[session]
        lock.unlock()

        stream.lock.lock()
        defer { stream.lock.unlock() }
        if let new { stream.viewers[id] = new }
        guard let viewer = stream.viewers[id] else { return nil }
        let outstanding = stream.take()
        let frame = hook?(session)
        var messages: [StreamMessage] = []
        if let frame {
            if frame.alternate {
                stream.onAlternateScreen.insert(id)
            } else {
                stream.onAlternateScreen.remove(id)
            }
            // A character the terminal has begun and not finished is in neither
            // the snapshot nor the bytes still to come, so it goes behind the
            // snapshot: the viewer then holds the same half the model does.
            messages = [.resize(cols: frame.size.cols, rows: frame.size.rows, own: false),
                        .snapshot(TerminalPaint.hardReset + frame.bytes + stream.pendingCharacter)]
        } else if new != nil, let grid {
            // No snapshot, but the grid is known: without it a new viewer would
            // render the stream on a grid of its own choosing. A size that changes
            // after it was read here is sent again by the resize that changed it,
            // which is queued behind this join. A viewer being resynchronised has
            // been sent every grid already.
            messages = [.resize(cols: grid.cols, rows: grid.rows, own: false)]
        }
        let everyoneElse = stream.viewers.filter { $0.key != id }.map(\.value.sink)
        // A new viewer without a snapshot starts from the stream after this point,
        // as it always has; a resync without one keeps the stream it had.
        let outstandingTo = frame == nil && new == nil ? everyoneElse + [viewer.sink] : everyoneElse
        return Join(outstanding: outstanding, outstandingTo: outstandingTo, viewer: viewer.sink,
                    messages: messages, snapshotBuilt: frame != nil, snapshotAsked: hook != nil)
    }

    /// Sends one viewer the grid and a snapshot again, joined to the stream as an
    /// attach is: the bytes accepted before the snapshot go to the other viewers
    /// first, and this one gets only what comes after it.
    ///
    /// For a viewer that has lost its place, which is what a `ViewerQueue` reports
    /// when it overflows. That report comes from inside a delivery, on `delivery`,
    /// while the bytes of that delivery are still on their way to the viewers after
    /// this one. So the join is queued behind it rather than run on the spot: run
    /// on the spot, the other viewers would get the next bytes before the ones
    /// being delivered.
    package func resync(connectionId: UUID, onUnavailable: @escaping @Sendable () -> Void) {
        delivery.async { [weak self] in
            guard let self, self.resyncNow(connectionId) else { return onUnavailable() }
        }
    }

    /// Call on `delivery`. Whether a snapshot was sent.
    @discardableResult
    private func resyncNow(_ id: UUID) -> Bool {
        lock.lock()
        let session = sessionForViewer[id]
        let stream = session.flatMap { streams[$0] }
        lock.unlock()
        guard let session, let stream,
              let join = join(stream, session: session, viewer: id) else { return false }
        join.deliver()
        guard join.snapshotBuilt else {
            GhosttyLog.stack.error("""
                no snapshot of session \(session, privacy: .public) for a resync
                """)
            return false
        }
        return true
    }

    /// Unregisters a viewer. The session's stream state stays: its bell tracker and
    /// its pending character describe the byte stream, not who is watching it.
    package func detach(connectionId: UUID) {
        lock.lock()
        let stream = sessionForViewer.removeValue(forKey: connectionId).flatMap { streams[$0] }
        lock.unlock()
        guard let stream else { return }
        stream.lock.lock()
        stream.viewers[connectionId] = nil
        stream.onAlternateScreen.remove(connectionId)
        stream.lock.unlock()
    }

    package func send(session: String, bytes: [UInt8]) {
        lock.lock()
        let handler = onInput
        lock.unlock()
        handler?(session, bytes)
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
    /// its PTY master. One entry point is what keeps one coalescing policy and one
    /// bell detector for every viewer, and it is what lets the screen model be fed
    /// at exactly the offset the viewers are served from: see `onIngest`.
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
        let alternateScreen = onAlternateScreen
        lock.unlock()

        stream.lock.lock()
        // Only with a viewer to deliver to: without one the flush would hand the
        // bytes to nobody, and every echoed keystroke of a terminal nobody watches
        // would pay a dispatch for it. The timer empties that buffer as before.
        let quiet = !stream.viewers.isEmpty
            && stream.buffer.isEmpty
            && DispatchTime.now().uptimeNanoseconds &- stream.lastFlush > Self.quietNanoseconds
        if quiet { stream.quietFlushes += 1 }
        stream.buffer.append(contentsOf: bytes)
        ingest?(session, bytes)
        stream.pendingCharacter = Self.incompleteCharacter(after: stream.pendingCharacter, bytes)
        let bells = bell == nil ? 0 : stream.tracker.bells(in: bytes)
        // A viewer that joined on the alternate screen holds an empty primary
        // screen underneath it, so when the terminal goes back to the primary
        // screen that viewer is sent the terminal again. Asked only while such a
        // viewer exists, which is not on the path of an ordinary stream.
        var leftAlternateScreen: Set<UUID> = []
        if !stream.onAlternateScreen.isEmpty, let alternateScreen, !alternateScreen(session) {
            leftAlternateScreen = stream.onAlternateScreen
            stream.onAlternateScreen = []
        }
        stream.lock.unlock()

        if quiet {
            delivery.async { [weak self, weak stream] in
                guard let self, let stream else { return }
                self.flush(stream, waiting: false)
            }
        }
        if !leftAlternateScreen.isEmpty {
            delivery.async { [weak self] in
                for id in leftAlternateScreen { self?.resyncNow(id) }
            }
        }
        // One call per counted bell: a program ringing twice in one write should
        // be reported twice, and an OSC terminator not at all.
        for _ in 0..<bells { bell?(session) }
    }

    /// The bytes at the end of the stream that start a UTF-8 character and do not
    /// finish it, given `carried`, the same answer for the stream before `bytes`.
    ///
    /// Constant time: only the last four bytes can matter, because a character is
    /// at most four bytes long. The bytes themselves are delivered as they came;
    /// this is only for what goes behind a snapshot or a repaint, so that a
    /// character cut by the moment of a join reaches the viewer whole. The model
    /// has its first half and has drawn nothing of it, so the frame does not
    /// show it, and the rest arrives in the stream after the frame.
    package static func incompleteCharacter(after carried: [UInt8], _ bytes: [UInt8]) -> [UInt8] {
        let window = bytes.count >= 4 ? Array(bytes.suffix(4)) : Array((carried + bytes).suffix(4))
        var index = window.count - 1
        while index >= 0 {
            let byte = window[index]
            if byte & 0xC0 != 0x80 {
                let length: Int
                switch byte {
                case 0xC2...0xDF: length = 2
                case 0xE0...0xEF: length = 3
                case 0xF0...0xF4: length = 4
                default: return []
                }
                return window.count - index < length ? Array(window[index...]) : []
            }
            index -= 1
        }
        return []
    }

    /// A session's grid changed, so tell its viewers.
    ///
    /// Every viewer is sent the new grid. One that asked for repaints is also sent
    /// the visible screen again, because the reflow rewrote it; one that reflows by
    /// itself gets nothing more.
    ///
    /// Deduped on the last size seen, because libghostty reports a grid on events
    /// (a font metric change, a re-parent) that need not have moved it.
    ///
    /// Called from the main actor. Safe: the state is lock guarded and the delivery
    /// itself is handed to `delivery`.
    package func noteSize(session: String, _ size: TerminalSize) {
        lock.lock()
        let changed = sizeForPane[session] != size
        sizeForPane[session] = size
        lock.unlock()
        guard changed else { return }
        delivery.async { [weak self] in self?.resizeNow(session: session, size) }
    }

    /// The same join an attach makes, for the same reason. What was accepted
    /// before the repaint is taken under the session's lock and delivered ahead of
    /// it, the repaint is taken under that same lock, and everything accepted
    /// afterwards follows it. So a repaint neither repeats a byte nor loses one.
    private func resizeNow(session: String, _ size: TerminalSize) {
        lock.lock()
        let hook = onRepaint
        let stream = streams[session]
        lock.unlock()
        guard let stream else { return }

        stream.lock.lock()
        let viewers = Array(stream.viewers.values)
        // Nothing is delivered without a viewer, so there is nothing to take and
        // nothing to paint either.
        guard !viewers.isEmpty else { stream.lock.unlock(); return }
        let outstanding = stream.take()
        let wantRepaint = viewers.contains { $0.resize == .repaint }
        let repaint = wantRepaint ? hook?(session) : nil
        let pending = stream.pendingCharacter
        stream.lock.unlock()

        let grid = repaint?.size ?? size
        if !outstanding.isEmpty { for viewer in viewers { viewer.sink(.data(outstanding)) } }
        for viewer in viewers {
            viewer.sink(.resize(cols: grid.cols, rows: grid.rows, own: false))
            if viewer.resize == .repaint, let repaint {
                viewer.sink(.repaint(TerminalPaint.reset + repaint.frame + pending))
            }
        }
        if wantRepaint, repaint == nil {
            // A frame that could not be built, not an empty screen. The viewer
            // keeps a screen laid out for the old grid until the stream redraws
            // it. Worth recording: it is indistinguishable from a working idle
            // terminal.
            GhosttyLog.stack.error("""
                could not paint session \(session, privacy: .public) for a repaint; \
                its viewers keep a stale screen
                """)
        }
    }

    /// How many writes into a session the quiet rule has sent straight to the
    /// delivery queue. For the tests: a dispatch that delivers nothing cannot be
    /// seen in what a viewer receives.
    package func quietFlushes(session: String) -> Int {
        lock.lock()
        let stream = streams[session]
        lock.unlock()
        guard let stream else { return 0 }
        stream.lock.lock()
        defer { stream.lock.unlock() }
        return stream.quietFlushes
    }

    /// Blocks until the delivery work already queued has run.
    ///
    /// A resize, a resync and a quiet flush are asynchronous by design, so a caller
    /// that triggers one and then wants to observe its result needs the barrier.
    /// Not to be called from a viewer's sink.
    package func waitForPendingDeliveries() {
        delivery.sync {}
    }

    /// Emits one `.data` per session holding accepted output.
    ///
    /// On `delivery`, like every other delivery, so a caller's flush and the
    /// timer's cannot take in one order and deliver in the other. Synchronous, so
    /// a test can assert on what a viewer received as soon as it returns. Not to
    /// be called from a viewer's sink, which already runs there.
    package func flush() {
        delivery.sync { flushNow(waiting: true) }
    }

    /// - Parameter waiting: whether to wait for a session whose lock is held. The
    ///   timer does not: a session's lock is held for as long as its model takes
    ///   to parse a chunk, and a model in the middle of reflowing a full
    ///   scrollback after a resize can hold a write behind it for a long time.
    ///   Waiting there would park this queue, and with it every other session's
    ///   viewers, behind one terminal. Skipped, that session's bytes stay where
    ///   they are and go out on the next tick, in order. A caller's own `flush()`
    ///   does wait, because it promises everything accepted has been delivered.
    private func flushNow(waiting: Bool) {
        lock.lock()
        let flushing = Array(streams.values)
        lock.unlock()
        for stream in flushing { flush(stream, waiting: waiting) }
    }

    /// Call on `delivery`. The only work under the session's lock is the swap of
    /// the buffer and the list of who to hand it to: that lock is also the one the
    /// terminal's writes take.
    private func flush(_ stream: Stream, waiting: Bool) {
        if waiting {
            stream.lock.lock()
        } else if !stream.lock.try() {
            return
        }
        guard !stream.buffer.isEmpty else { stream.lock.unlock(); return }
        let bytes = stream.take()
        stream.lastFlush = DispatchTime.now().uptimeNanoseconds
        let sinks = stream.viewers.values.map(\.sink)
        stream.lock.unlock()
        for sink in sinks { sink(.data(bytes)) }
    }
}
