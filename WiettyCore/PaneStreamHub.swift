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
///
/// That is for a queued viewer, the kind the WebSocket route attaches. A local
/// viewer (`attachLocal`) is the other kind: it is written to on the writer's own
/// thread, one write per chunk, with a call that may block and so holds the writer
/// back, and it is never dropped. `LocalStreamServer` attaches one for each of the
/// app's own panes.
package final class PaneStreamHub: ScreenStreaming, @unchecked Sendable {
    private typealias Sink = @Sendable (StreamMessage) -> Void

    /// A queued viewer: handed its messages on `delivery`, after the bytes were
    /// batched. What the WebSocket route attaches.
    private struct Viewer {
        let sink: Sink
        let resize: ResizeMode
    }

    /// A local viewer: written to directly, by whichever thread has a message for
    /// it, with a call that may block. What the Mac's own pane attaches.
    ///
    /// **One writer at a time, and the rule that orders it.** At most one thread
    /// writes to the viewer at a time: the one that made it `busy`. A thread with
    /// messages for it decides what to do while holding the session's lock, under
    /// `state`: if the viewer is idle it becomes the writer, releases the session's
    /// lock and writes; if it is busy, the writer thread (the pty's) waits for it,
    /// still holding the session's lock, because that wait is the backpressure,
    /// while `delivery` leaves its messages in `pending` and moves on. Whoever
    /// becomes the writer next writes what is pending first. `delivery` as writer
    /// also writes what was left while it wrote, until none is; the pty's thread
    /// does not, and hands what is left to `delivery` (see `run`). Checking
    /// `pending` and giving the viewer up are one critical section, so a message
    /// left at the instant a writer finishes is never stranded.
    ///
    /// So the order the viewer sees is the order in which the session's lock was
    /// held for its messages: a chunk taken as writer before a resize is written
    /// before it, a resize left pending during a chunk is written after that chunk
    /// and before the next, since the next chunk's writer either waits for the
    /// drain or takes the resize first.
    ///
    /// **`pending` holds control messages only**: `resize`, `repaint` and `ended`,
    /// never output, which only the pty's thread writes and only as the writer. It
    /// grows only while one write is in progress, by one group per grid change or
    /// claim answered in that time, and it is coalesced as it grows: no output lies
    /// between two pending messages, so a later group with a repaint replaces every
    /// earlier pending repaint and `own: false` resize, and for a viewer that
    /// reflows a later `resize` replaces every earlier `own: false` one. What is
    /// never replaced is a claim's answer, `own: true`, which every claim needs:
    /// there is one per claim this viewer itself made while it was not reading.
    ///
    /// `@unchecked Sendable`: the immutable fields are immutable, and the others are
    /// read and written under `state`, a leaf: nothing else is taken while it is held.
    private final class LocalViewer: @unchecked Sendable {
        let id: UUID
        let resize: ResizeMode
        private let write: Sink
        /// Called once, with no lock held, after `ended` was written.
        private let onEnded: @Sendable () -> Void
        private let state = NSCondition()
        private var gone = false
        /// Reserved by a writer: what orders the messages. Set when a writer is
        /// chosen, which for several local viewers of one session is before it
        /// writes to any of them.
        private var busy = false
        /// Inside a call to `write` now, and on which thread (`currentThread()`).
        /// What `detach` waits for: a reserved viewer whose writer is still busy
        /// with another viewer is not waited for.
        private var calling = false
        private var writer: UInt64 = 0
        private var pending: [StreamMessage] = []

        init(id: UUID, resize: ResizeMode, write: @escaping Sink, onEnded: @escaping @Sendable () -> Void) {
            self.id = id
            self.resize = resize
            self.write = write
            self.onEnded = onEnded
        }

        static func currentThread() -> UInt64 {
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            return id
        }

        var isGone: Bool {
            state.lock()
            defer { state.unlock() }
            return gone
        }

        /// Offers `messages` to the viewer. Call holding the session's lock, except
        /// for a drain, which offers nothing. When the caller has become the writer,
        /// returns what it must write once it has released that lock: whatever was
        /// left pending, then `messages`. Nil when there is nothing more to do: the
        /// viewer is gone, or it is busy and the messages were left pending.
        ///
        /// - Parameter waitIfBusy: true for the pty's thread, which waits until the
        ///   viewer is no longer reserved by another writer or has been marked gone
        ///   (`detach` and `stop` wake it at once): the backpressure. False for
        ///   `delivery`, which never waits.
        func offer(_ messages: [StreamMessage], waitIfBusy: Bool) -> [StreamMessage]? {
            state.lock()
            defer { state.unlock() }
            while waitIfBusy, busy, !gone { state.wait() }
            if gone { return nil }
            if busy {
                leave(messages)
                return nil
            }
            busy = true
            let batch = pending + messages
            pending = []
            return batch
        }

        /// Appends a group to `pending`, coalescing as described on the type.
        /// Call under `state`.
        private func leave(_ group: [StreamMessage]) {
            let repaints = group.contains { if case .repaint = $0 { true } else { false } }
            let resizes = group.contains { if case .resize = $0 { true } else { false } }
            if repaints || (resizes && resize == .reflow) {
                pending.removeAll { message in
                    switch message {
                    case .repaint: return repaints
                    case let .resize(_, _, own): return !own
                    default: return false
                    }
                }
            }
            pending.append(contentsOf: group)
        }

        /// Writes `batch`, the result of `offer`, and gives the viewer up. Call with
        /// no lock held.
        ///
        /// What was left pending meanwhile is written too when `drainingAll`, which
        /// is for `delivery`: nobody leaves anything while `delivery` itself writes,
        /// so the loop ends. The pty's thread does not drain: messages keep coming
        /// while it writes (a window drag into a pane that reads slowly), and draining
        /// them all could keep it from its next chunk for as long as they come. It
        /// gives the viewer up instead and returns true, and the caller has
        /// `delivery` drain it (`drainLocal`). Either way the check for a pending
        /// message and giving the viewer up are one critical section, so nothing left
        /// at that instant is stranded, and a pending message precedes the next
        /// chunk, since the next writer takes it first (`offer`).
        func run(_ batch: [StreamMessage], drainingAll: Bool) -> Bool {
            var batch = batch
            var ended = false
            while true {
                for message in batch {
                    // The check and the mark are one step under `state`, so a
                    // `detach` either sees the call coming or stops it.
                    state.lock()
                    if gone { state.unlock(); break }
                    calling = true
                    writer = Self.currentThread()
                    state.unlock()
                    write(message)
                    state.lock()
                    calling = false
                    writer = 0
                    state.broadcast()
                    state.unlock()
                    if case .ended = message {
                        state.lock(); gone = true; state.unlock()
                        ended = true
                        break
                    }
                }
                state.lock()
                if gone { pending = [] }
                if pending.isEmpty || !drainingAll {
                    let leftover = !pending.isEmpty
                    busy = false
                    state.broadcast()
                    state.unlock()
                    if ended { onEnded() }
                    return leftover
                }
                batch = pending
                pending = []
                state.unlock()
            }
        }

        /// Marks the viewer gone and waits until no call to its `write` is running,
        /// unless the call running is this thread's own (a detach from inside
        /// `write`). Waits for nothing else: not for a reservation, so a writer
        /// blocked on another viewer of the session does not hold this up. The
        /// broadcast wakes a pty thread waiting in `offer` for this viewer, which
        /// then finds it gone.
        func detach() {
            state.lock()
            gone = true
            pending = []
            state.broadcast()
            let me = Self.currentThread()
            while calling, writer != me { state.wait() }
            state.unlock()
        }

        /// Marks the viewer gone without waiting: no further call starts, and one in
        /// progress runs to its end.
        func markGone() {
            state.lock()
            gone = true
            pending = []
            state.broadcast()
            state.unlock()
        }
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
    /// Nothing is delivered under it: what is taken is handed to the queued
    /// viewers after it is released, on `delivery`, which is what orders their
    /// deliveries. Who writes to a local viewer is decided under it instead, and
    /// the write made after it is released: see `LocalViewer`.
    ///
    /// Per session rather than one for the hub, because a parse runs under it: a
    /// terminal printing a build log must not hold up the bytes of the terminal
    /// next to it.
    ///
    /// `@unchecked Sendable` because every field is read and written under `lock`,
    /// except `skippedFlushes`, which only `delivery` touches, and `flushWanted`,
    /// which is guarded by `flushTurn`.
    private final class Stream: @unchecked Sendable {
        let lock = NSLock()
        /// What has been accepted and not yet delivered to the queued viewers. A
        /// local viewer has been given every byte already, so a session whose only
        /// viewers are local keeps nothing here.
        var buffer: [UInt8] = []
        var tracker = OSCStringTracker()
        /// The queued viewers.
        var viewers: [UUID: Viewer] = [:]
        /// The local viewers. One that is gone stays here until the next holder of
        /// the lock drops it, because `detach` does not take this lock.
        var locals: [UUID: LocalViewer] = [:]
        /// Whether `onLocalViewerAttached` has been called for this session.
        var localAttachReported = false
        /// Ticks in a row on which a flush found this session's lock held. Only
        /// `delivery` reads or writes it.
        var skippedFlushes = 0
        /// Set by a flush that has skipped this session too often, so the writer
        /// stands aside at the start of its next write. Guarded by `flushTurn`.
        let flushTurn = NSCondition()
        var flushWanted = false
        /// Which request `flushWanted` is, and the last one the writer stood aside
        /// for, so a writer waits once per request. Guarded by `flushTurn`.
        var flushRequest: UInt64 = 0
        var yieldedTo: UInt64 = 0
        /// Whether this session had a queued viewer when `delivery` last looked
        /// (on a flush that got the lock, or a queued attach). A flush does not ask
        /// the writer to stand aside for a session without one. Only `delivery`
        /// reads or writes it.
        var queuedSeen = false
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

        /// The local viewers still attached, in the order of their ids. Drops the
        /// ones that are gone. Call under `lock`.
        func liveLocals() -> [LocalViewer] {
            guard !locals.isEmpty else { return [] }
            var live = locals.values.filter { !$0.isGone }
            if live.count != locals.count { locals = locals.filter { !$0.value.isGone } }
            if live.count > 1 { live.sort { $0.id.uuidString < $1.id.uuidString } }
            return live
        }

        /// Called by the writer before it takes `lock`: while a flush is waiting for
        /// its turn, the writer waits for it, up to `limit` seconds, once per
        /// request. Without this a writer holding the lock back to back (a flood
        /// parsed chunk after chunk) is never caught with it free: `NSLock` is not
        /// fair, and a waiter loses to a thread that unlocks and locks again.
        func standAsideForAFlush(limit: TimeInterval) {
            flushTurn.lock()
            if flushWanted, yieldedTo != flushRequest {
                yieldedTo = flushRequest
                let deadline = Date(timeIntervalSinceNow: limit)
                while flushWanted, flushTurn.wait(until: deadline) {}
            }
            flushTurn.unlock()
        }

        /// Asks the writer to stand aside and tries for `lock` until `limit`
        /// seconds have passed. Whether it got the lock. Call on `delivery`.
        ///
        /// The request stays up when it gives up, so the writer stands aside at the
        /// start of its next write and the next tick finds the lock free: a session
        /// is skipped at most `skipsBeforeWaiting` + 2 ticks in a row, as long as no
        /// single write holds the lock longer than a tick and this limit together.
        func lockWithTheWritersHelp(limit: TimeInterval) -> Bool {
            flushTurn.lock()
            if !flushWanted {
                flushWanted = true
                flushRequest &+= 1
            }
            flushTurn.unlock()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(limit * 1e9)
            var locked = lock.try()
            while !locked, DispatchTime.now().uptimeNanoseconds < deadline {
                usleep(50)
                locked = lock.try()
            }
            if locked { flushTaken() }
            return locked
        }

        /// The flush has the lock: the writer may go on. Call on `delivery`.
        func flushTaken() {
            flushTurn.lock()
            if flushWanted {
                flushWanted = false
                flushTurn.broadcast()
            }
            flushTurn.unlock()
        }
    }

    /// Guards the registry below and the hooks. Held for a lookup and never while
    /// a session's own lock is taken, so there is no order between the two to get
    /// wrong.
    private let lock = NSLock()
    private var streams: [String: Stream] = [:]
    /// The session of every viewer, queued or local.
    private var sessionForViewer: [UUID: String] = [:]
    /// The local viewers by id, so `detach` can mark one gone without taking its
    /// session's lock.
    private var localViewers: [UUID: LocalViewer] = [:]
    /// The grid in force for a session: the last one a viewer claimed through
    /// `claim` (or the model's, when it announced another), and absent before the
    /// first claim, while the terminal is at the grid it was spawned with. Written on
    /// `delivery` only, by `claimNow` and `resizeNow`: a claim is the one thing that
    /// moves a terminal's grid (decision P4), so the record, the pty, the model and
    /// what the viewers are told change in one serial order. Read under `lock` by
    /// those two and by an attach's join, which `attach` and `attachLocal` run with
    /// `delivery.sync`: possibly on the attaching thread (a connection's, for a local
    /// viewer), but serialized with every write. The join uses it only for a viewer
    /// that gets no snapshot.
    private var sizeForPane: [String: TerminalSize] = [:]
    private var timer: DispatchSourceTimer?
    /// Where everything that delivers to a viewer runs: the flush timer, a quiet
    /// flush, an attach, a resync, a resize and an ending. The one exception is
    /// output for a local viewer, written on the writer's thread.
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
    /// Resizes the pty and the model of a session. Called before the repaint is taken.
    ///
    /// Called on `delivery` with no lock of the hub's held, because it takes the
    /// model's lock and signals the child. It must not call back into the hub.
    package var onClaim: (@Sendable (_ session: String, _ size: TerminalSize) -> Void)?
    /// Called once per session, when its first local viewer has been sent its
    /// snapshot (or, with no snapshot to send, whatever its attach was sent).
    ///
    /// Called on `delivery` with no lock of the hub's held, before that viewer's
    /// `attachLocal` returns. It must not call `attach`, `attachLocal`, `flush` or
    /// `waitForPendingDeliveries`, which wait for `delivery`.
    package var onLocalViewerAttached: (@Sendable (_ session: String) -> Void)?

    /// Interval chosen so typing feels immediate while a burst of output still
    /// coalesces into one message.
    private static let flushInterval = DispatchTimeInterval.milliseconds(8)
    /// The same interval, for the quiet rule: a write into an empty buffer of a session
    /// that has a viewer goes out at once when the last flush is older than this.
    private static let quietNanoseconds: UInt64 = 8_000_000
    /// The largest `data` message a queued viewer is handed. A larger take, which a
    /// flood can build in one interval, goes out as several, in order: one message
    /// over the 4 MiB a `ViewerQueue` holds would overflow it even when empty.
    private static let maxDataMessage = 256 * 1024
    /// Ticks in a row a flush skips a session whose lock is held before it asks
    /// the writer to stand aside and waits for its turn.
    private static let skipsBeforeWaiting = 3
    /// How long a flush that waits for its turn waits, at most, before it skips
    /// the session for this tick after all. Bounded so a session stuck under its
    /// lock (a model reflowing a full scrollback) costs every other session this
    /// much per tick, rather than parking `delivery` for as long as it is stuck.
    private static let flushWaitLimit: TimeInterval = 0.004
    /// How long a writer stands aside for a flush, at most. Longer than the flush
    /// waits, so the writer is never the one that gives up first.
    private static let writerYieldLimit: TimeInterval = 0.02

    /// `bytes` as `data` messages of at most `maxDataMessage` bytes each.
    private static func dataMessages(_ bytes: [UInt8]) -> [StreamMessage] {
        guard bytes.count > maxDataMessage else { return bytes.isEmpty ? [] : [.data(bytes)] }
        return stride(from: 0, to: bytes.count, by: maxDataMessage).map {
            .data(Array(bytes[$0..<min($0 + maxDataMessage, bytes.count)]))
        }
    }

    /// Hands `bytes` to each sink, as `data` messages of at most `maxDataMessage`.
    private static func deliver(_ bytes: [UInt8], to sinks: [Sink]) {
        guard !bytes.isEmpty, !sinks.isEmpty else { return }
        let messages = dataMessages(bytes)
        for sink in sinks {
            for message in messages { sink(message) }
        }
    }

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
        // A local viewer stays in `localViewers` until its `ended` has been written
        // (`forgetLocal`), so a `detach` meanwhile finds it and waits for that write.
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
            // A local viewer has every byte already. One that is writing a chunk
            // is left its `ended`, which it writes after that chunk.
            let locals = stream.liveLocals()
            stream.locals = [:]
            let writing = locals.compactMap { local in
                local.offer([.ended], waitIfBusy: false).map { (local, $0) }
            }
            stream.lock.unlock()
            for (local, batch) in writing { _ = local.run(batch, drainingAll: true) }
            for sink in sinks {
                for message in Self.dataMessages(bytes) { sink(message) }
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
        stream.queuedSeen = true
        join.deliver()
        if !join.snapshotBuilt, join.snapshotAsked {
            GhosttyLog.stack.error("""
                no snapshot of session \(session, privacy: .public) for a viewer attaching; \
                it starts from the stream alone
                """)
        }
    }

    /// Attaches a viewer that is never dropped. `write` is called with each message in
    /// order and may block: while it does, the thread that reads the pty waits.
    ///
    /// The attach itself is the join `attach` makes, with the same messages: a
    /// `resize` and a `snapshot`, the started half of a character behind the
    /// snapshot, and every byte accepted afterwards in the stream. What differs is
    /// how the stream reaches it.
    ///
    /// **Where `write` is called.** Output is written on the thread that calls
    /// `write(session:bytes:)`, the pty's read thread, before that call returns: no
    /// batching and no hop to `delivery`. Every other message (the attach's, a
    /// `resize`, a `repaint` for `.repaint`, a claim's answer, `ended`) comes from
    /// `delivery`: written there when the viewer is idle, and otherwise left with the
    /// viewer and written after the chunk in progress, by `delivery` once the
    /// viewer is idle or by the next chunk's writer ahead of that chunk.
    /// Calls never overlap, they come in stream order, and no lock of the hub's is
    /// held across one. See `LocalViewer`.
    ///
    /// **The cost, in two cases.** When the pane stops reading while output is
    /// being written to it (the usual case, the pty's thread is the writer): that
    /// terminal's pty read waits and so does its child; its other local viewers
    /// get nothing until it reads; a `resize`, a claim's answer and an `ended` for
    /// its local viewers are left with the viewer and delivered when it reads;
    /// nothing else waits. `detach` of that viewer waits for the blocked write, so
    /// its owner shuts the socket down first.
    ///
    /// When `delivery` itself is the writer (the snapshot on attach, or a `resize`,
    /// a claim's answer, an `ended` or a drain sent to a viewer that was idle) and
    /// the pane stops reading in the middle of that write: `delivery` is parked
    /// until the pane reads or the owner shuts the socket down. While it is parked
    /// no queued viewer of any terminal receives anything, nobody can attach,
    /// other terminals' buffers grow, and their WebSocket viewers are
    /// resynchronised afterwards. Apart from a pane that stops in the middle of its
    /// first snapshot, this takes a transport that refuses a message of a few
    /// dozen bytes: a socket buffer already full on a terminal that is producing
    /// nothing. The transport's owner should give the socket a send buffer large
    /// enough for control messages.
    ///
    /// **What `write` may call.** `claim`, `resync`, `send`, and `detach` of this
    /// viewer itself, which then returns at once. Not `write(session:bytes:)`,
    /// `attach`, `attachLocal`, `flush`, `waitForPendingDeliveries`, `detach` of any
    /// other viewer: each of those waits for a session's lock, for `delivery` or for
    /// another write, and the holder may be waiting for this very call.
    ///
    /// **What the transport may not do.** The thread that drains this viewer's
    /// transport (reads the socket `write` writes into, at its other end) must never
    /// wait on the hub: no `attach`, no `attachLocal`, no `detach` of a queued
    /// viewer, no `detach` of this local viewer either (it waits for a write in
    /// progress), nothing that waits for `delivery` or a session's lock, neither
    /// directly nor through anything it waits for: the main actor, the cooperative
    /// pool, another thread. Those can be waiting for a `write` that only that
    /// thread's reading lets return.
    ///
    /// **Detaching.** After `detach(connectionId:)` returns, this viewer's `write` is
    /// not running and will never be called again, unless `detach` was called from
    /// inside that viewer's own `write`, in which case it returns at once and the
    /// call in progress is the last. `detach` waits for a call in progress to
    /// return and for nothing else, so a blocked call must be released first: the
    /// owner shuts its socket down (which makes a blocked write fail), then calls
    /// `detach`, then closes the descriptor. `detach` of a local viewer must not be
    /// called on `delivery` (a queued viewer's sink, a hook), which would then wait
    /// for a pane. After an ending, `ended` is the last call.
    ///
    /// Never resynchronised and never dropped: `resync` for its id answers
    /// `onUnavailable`, and the alternate screen rule does not apply to it, because
    /// it attaches when the terminal opens and is given every byte after that.
    ///
    /// Runs on `delivery`, synchronously, as `attach` does. Not to be called from a
    /// viewer's sink or `write`.
    @discardableResult
    package func attachLocal(session: String, resize: ResizeMode,
                             write: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        let id = UUID()
        let viewer = LocalViewer(id: id, resize: resize, write: write) { [weak self] in
            self?.forgetLocal(id)
        }
        delivery.sync { attachLocalNow(viewer, session: session) }
        return viewer.id
    }

    private func attachLocalNow(_ viewer: LocalViewer, session: String) {
        lock.lock()
        let census = onSessionCensus
        lock.unlock()
        // As for `attach`: a session that can never produce a byte is ended at once.
        if let census, !Self.isStreamable(session: session, census: census()) {
            // Never registered, so nobody else can reach it.
            if let batch = viewer.offer([.ended], waitIfBusy: false) { _ = viewer.run(batch, drainingAll: true) }
            return
        }
        lock.lock()
        let stream = streams[session] ?? Stream()
        streams[session] = stream
        sessionForViewer[viewer.id] = session
        localViewers[viewer.id] = viewer
        let hook = onSnapshot
        let grid = sizeForPane[session]
        lock.unlock()

        stream.lock.lock()
        stream.locals[viewer.id] = viewer
        // The join: what was accepted before the snapshot goes to the queued
        // viewers, and this one gets the snapshot that holds it.
        let outstanding = stream.take()
        let frame = hook?(session)
        var messages: [StreamMessage] = []
        if let frame {
            // The started half of a character goes behind the snapshot, and the
            // rest follows in the stream, as for a queued viewer.
            messages = [.resize(cols: frame.size.cols, rows: frame.size.rows, own: false),
                        .snapshot(TerminalPaint.hardReset + frame.bytes + stream.pendingCharacter)]
        } else if let grid {
            messages = [.resize(cols: grid.cols, rows: grid.rows, own: false)]
        }
        let sinks = stream.viewers.values.map(\.sink)
        let first = !stream.localAttachReported
        stream.localAttachReported = true
        // New, so idle: this thread becomes its writer, and a chunk the writer
        // thread accepts from now on waits for the attach's messages.
        let batch = viewer.offer(messages, waitIfBusy: false)
        stream.lock.unlock()
        if let batch { _ = viewer.run(batch, drainingAll: true) }

        Self.deliver(outstanding, to: sinks)
        if first {
            lock.lock()
            let attached = onLocalViewerAttached
            lock.unlock()
            attached?(session)
        }
        if frame == nil, hook != nil {
            GhosttyLog.stack.error("""
                no snapshot of session \(session, privacy: .public) for a local viewer \
                attaching; it starts from the stream alone
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
            PaneStreamHub.deliver(outstanding, to: outstandingTo)
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
    ///
    /// A local viewer is never resynchronised: for its id the join finds no queued
    /// viewer, and `onUnavailable` is called.
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
    ///
    /// A local viewer is marked gone, and then this waits until its `write` is not
    /// running (unless called from inside it), without taking its session's lock,
    /// which the pty's thread may hold while it waits for that very write. See
    /// `attachLocal` for the contract.
    package func detach(connectionId: UUID) {
        lock.lock()
        let session = sessionForViewer.removeValue(forKey: connectionId)
        let local = localViewers.removeValue(forKey: connectionId)
        let stream = session.flatMap { streams[$0] }
        lock.unlock()
        if let local {
            local.detach()
            // Dropped from the session now if its lock is free, so nothing the
            // viewer holds outlives the detach on an idle terminal; otherwise the
            // next holder of the lock drops it.
            if let stream, stream.lock.try() {
                stream.locals[connectionId] = nil
                stream.lock.unlock()
            }
            return
        }
        guard let stream else { return }
        stream.lock.lock()
        stream.viewers[connectionId] = nil
        stream.onAlternateScreen.remove(connectionId)
        stream.lock.unlock()
    }

    /// Writes what the pty's thread left pending for a local viewer when it gave it
    /// up. On `delivery`. A viewer busy again by now is left alone: its writer takes
    /// the pending messages first.
    private func drainLocal(_ local: LocalViewer) {
        if let batch = local.offer([], waitIfBusy: false) { _ = local.run(batch, drainingAll: true) }
    }

    /// Drops an ended local viewer from the registry, once its `ended` has been
    /// written and its writer has given it up. Called by that writer, with no lock
    /// held. Its session goes too: a `detach` of the id afterwards must find nothing,
    /// not take the queued viewer's path and wait for a session's lock.
    private func forgetLocal(_ id: UUID) {
        lock.lock()
        localViewers[id] = nil
        sessionForViewer[id] = nil
        lock.unlock()
    }

    package func send(session: String, bytes: [UInt8]) {
        lock.lock()
        let handler = onInput
        lock.unlock()
        handler?(session, bytes)
    }

    /// Drops the viewers and their buffers, and stops the flush timer. The sizes
    /// survive: a session id stays valid across a stop and start, and clearing them
    /// would make the next claim of the grid in force look like a change.
    package func stop() {
        lock.lock()
        streams = [:]
        sessionForViewer = [:]
        // Left in `localViewers`, so a `detach` afterwards still finds each one
        // and waits for a write in progress.
        let locals = Array(localViewers.values)
        let source = timer
        timer = nil
        lock.unlock()
        // As a detach: no further call to their `write` starts.
        for local in locals { local.markGone() }
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
    ///
    /// The session's local viewers are written to here, on the caller's thread,
    /// before this returns, so a local viewer whose `write` blocks holds the caller
    /// with it. That is the backpressure: the caller is the thread reading the pty,
    /// and the child waits on a full pty as it would on a slow terminal.
    package func write(session: String, bytes: [UInt8]) {
        lock.lock()
        let stream = streams[session] ?? Stream()
        streams[session] = stream
        let ingest = onIngest
        let bell = onBell
        let alternateScreen = onAlternateScreen
        lock.unlock()

        stream.standAsideForAFlush(limit: Self.writerYieldLimit)
        stream.lock.lock()
        let locals = stream.liveLocals()
        // Only with a queued viewer to deliver to: without one the flush would hand
        // the bytes to nobody, and every echoed keystroke of a terminal nobody
        // watches would pay a dispatch for it. The timer empties that buffer as
        // before. A local viewer is written to below and never needs it.
        let queued = !stream.viewers.isEmpty
        let quiet = queued
            && stream.buffer.isEmpty
            && DispatchTime.now().uptimeNanoseconds &- stream.lastFlush > Self.quietNanoseconds
        if quiet { stream.quietFlushes += 1 }
        // Kept for the queued viewers, and, as before, for a session nobody
        // watches yet; not for a session whose only viewers are local.
        if queued || locals.isEmpty { stream.buffer.append(contentsOf: bytes) }
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
        // Under the session's lock, so this chunk reaches each local viewer ahead
        // of anything a later holder of the lock has for it: a repaint taken from
        // a model that has parsed this chunk, say. A viewer still busy with the
        // last message `delivery` wrote to it is waited for here: the backpressure.
        let messages = locals.isEmpty ? [] : Self.dataMessages(bytes)
        let writing = messages.isEmpty ? [] : locals.compactMap { local in
            local.offer(messages, waitIfBusy: true).map { (local, $0) }
        }
        stream.lock.unlock()

        // The queued viewers' dispatches first, so they are not held behind a
        // local viewer that blocks.
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
        for (local, batch) in writing where local.run(batch, drainingAll: false) {
            delivery.async { [weak self] in self?.drainLocal(local) }
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

    /// The grids a viewer may claim, the same bounds the codec keeps for a `resize`.
    private static let claimable = 1...10_000

    /// A viewer says "I am active, this is my grid".
    ///
    /// A grid other than the one in force becomes it: `onClaim` resizes the pty and
    /// the model, and then every viewer is told as for any resize, `own` true for
    /// the claimant alone. The grid in force already moves nothing and is answered
    /// to the claimant alone, so every claim gets exactly one answer, in order. A
    /// viewer that is not attached, or a grid outside `claimable`, claims nothing
    /// and is not answered.
    ///
    /// Safe from any thread, and asynchronous like a resize: handled on `delivery`,
    /// so the bytes accepted before it is handled reach the claimant before its
    /// answer, and the main actor plays no part.
    package func claim(connectionId: UUID, cols: Int, rows: Int) {
        guard Self.claimable.contains(cols), Self.claimable.contains(rows) else { return }
        let size = TerminalSize(cols: cols, rows: rows)
        delivery.async { [weak self] in self?.claimNow(connectionId, size) }
    }

    /// Call on `delivery`. The record is read and written here rather than when the
    /// claim is made, so claims are judged in the order they are handled.
    private func claimNow(_ id: UUID, _ size: TerminalSize) {
        lock.lock()
        guard let session = sessionForViewer[id], let stream = streams[session] else {
            lock.unlock()
            return
        }
        let changed = sizeForPane[session] != size
        sizeForPane[session] = size
        let resizer = onClaim
        lock.unlock()
        guard changed else { return answerClaimant(id, of: stream, size) }
        // The pty and the model first, with no lock of the hub's held, and only then
        // the repaint: taken before, it would paint the screen as it was before the
        // reflow.
        resizer?(session, size)
        resizeNow(session: session, size, claimant: id)
    }

    /// The answer to a claim for the grid in force: the bytes accepted so far go to
    /// every viewer, as a flush would send them, so that the claimant gets them
    /// ahead of the answer, and then the claimant alone is sent the grid.
    ///
    /// A local claimant has every byte already and is sent the grid alone, through
    /// its write lock.
    private func answerClaimant(_ id: UUID, of stream: Stream, _ size: TerminalSize) {
        let answer = StreamMessage.resize(cols: size.cols, rows: size.rows, own: true)
        stream.lock.lock()
        if let local = stream.locals[id] {
            let batch = local.offer([answer], waitIfBusy: false)
            stream.lock.unlock()
            if let batch { _ = local.run(batch, drainingAll: true) }
            return
        }
        guard let claimant = stream.viewers[id] else { stream.lock.unlock(); return }
        let outstanding = stream.take()
        let sinks = stream.viewers.values.map(\.sink)
        stream.lock.unlock()
        Self.deliver(outstanding, to: sinks)
        claimant.sink(answer)
    }

    /// The same join an attach makes, for the same reason. What was accepted
    /// before the repaint is taken under the session's lock and delivered ahead of
    /// it, the repaint is taken under that same lock, and everything accepted
    /// afterwards follows it. So a repaint neither repeats a byte nor loses one.
    ///
    /// The grid announced is the repaint's when there is one, which is the model's
    /// and can differ from `size`; it then becomes the record, so a later claim
    /// is judged against what the viewers were told.
    ///
    /// - Parameter claimant: the viewer whose claim moved the grid, the one told
    ///   `own` true.
    private func resizeNow(session: String, _ size: TerminalSize, claimant: UUID) {
        lock.lock()
        let hook = onRepaint
        let stream = streams[session]
        lock.unlock()
        guard let stream else { return }

        stream.lock.lock()
        let viewers = Array(stream.viewers)
        let locals = stream.liveLocals()
        // Nothing is delivered without a viewer, so there is nothing to take and
        // nothing to paint either.
        guard !viewers.isEmpty || !locals.isEmpty else { stream.lock.unlock(); return }
        // The outstanding bytes are the queued viewers'. A local viewer has been
        // given every byte accepted so far, or is being given the last chunk by the
        // writer, which writes what is left pending here after that chunk.
        let outstanding = stream.take()
        let wantRepaint = viewers.contains { $0.value.resize == .repaint }
            || locals.contains { $0.resize == .repaint }
        let repaint = wantRepaint ? hook?(session) : nil
        let pending = stream.pendingCharacter
        let grid = repaint?.size ?? size
        let writing = locals.compactMap { local -> (LocalViewer, [StreamMessage])? in
            var messages: [StreamMessage] = [.resize(cols: grid.cols, rows: grid.rows, own: local.id == claimant)]
            if local.resize == .repaint, let repaint {
                messages.append(.repaint(TerminalPaint.reset + repaint.frame + pending))
            }
            return local.offer(messages, waitIfBusy: false).map { (local, $0) }
        }
        stream.lock.unlock()

        if grid != size {
            lock.lock()
            // On `delivery`, as every write of the record is, so nothing has
            // replaced the claim's record since `claimNow` wrote it.
            sizeForPane[session] = grid
            lock.unlock()
        }
        // The idle local viewers are written here; a busy one writes its own after
        // the chunk in progress.
        for (local, batch) in writing { _ = local.run(batch, drainingAll: true) }
        Self.deliver(outstanding, to: viewers.map(\.value.sink))
        for (id, viewer) in viewers {
            viewer.sink(.resize(cols: grid.cols, rows: grid.rows, own: id == claimant))
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

    /// How many bytes a session holds for its queued viewers and has not delivered.
    /// For the tests: a session whose only viewers are local must hold none.
    package func bufferedBytes(session: String) -> Int {
        lock.lock()
        let stream = streams[session]
        lock.unlock()
        guard let stream else { return 0 }
        stream.lock.lock()
        defer { stream.lock.unlock() }
        return stream.buffer.count
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
    ///   they are and go out on a later tick, in order; how many ticks in a row
    ///   it may be skipped is bounded, see `flush(_:waiting:)`. A caller's own `flush()`
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
    ///
    /// Skipped, but not without limit: a writer that holds the lock back to back,
    /// parsing a flood chunk after chunk, would never be caught with it free. After
    /// `skipsBeforeWaiting` ticks in a row the flush asks the writer to stand aside
    /// and waits for the lock, up to `flushWaitLimit`.
    private func flush(_ stream: Stream, waiting: Bool) {
        if waiting {
            stream.lock.lock()
        } else if !stream.lock.try() {
            // Only a session with a queued viewer is worth a writer standing aside:
            // without one this flush would hand the bytes to nobody.
            guard stream.queuedSeen else { return }
            stream.skippedFlushes += 1
            guard stream.skippedFlushes > Self.skipsBeforeWaiting,
                  stream.lockWithTheWritersHelp(limit: Self.flushWaitLimit) else { return }
        }
        stream.flushTaken()
        stream.skippedFlushes = 0
        stream.queuedSeen = !stream.viewers.isEmpty
        guard !stream.buffer.isEmpty else { stream.lock.unlock(); return }
        let bytes = stream.take()
        stream.lastFlush = DispatchTime.now().uptimeNanoseconds
        let sinks = stream.viewers.values.map(\.sink)
        stream.lock.unlock()
        Self.deliver(bytes, to: sinks)
    }
}
