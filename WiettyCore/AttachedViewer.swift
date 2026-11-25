import Foundation
import WiettyShared

/// One WebSocket viewer of one session, between the hub and the socket: the
/// viewer's bounded `ViewerQueue`, its registration with the streamer, and the
/// rate limited answer to an overflow.
///
/// The route owns one per accepted `/attach` socket. Building it pushes `greeting`
/// (the server's `hello`) and then attaches, so the hello is queued ahead of
/// everything the hub sends. One writer drains `queue`; `close()` ends it all.
///
/// **An overflow is answered through `ResyncThrottle`**, at most one resync per
/// interval, and every resync that cannot be answered with a snapshot reaches the
/// queue as `resyncUnavailable()`, once. An overflow can come before `attach` has
/// returned the viewer's id (the hub's delivery queue may already be fanning out
/// output while the attaching thread has not yet stored it). The resync is then
/// held and asked for as soon as the id is known, so it is never lost.
///
/// Built and tested without a socket: the route adds only the socket around it.
package final class AttachedViewer: @unchecked Sendable {
    package let queue: ViewerQueue
    private let streamer: any ScreenStreaming
    private let throttle: ResyncThrottle

    private let lock = NSLock()
    private var connectionId: UUID?
    /// A resync was due before `connectionId` was known.
    private var resyncBeforeId = false
    private var closed = false

    /// - Parameters:
    ///   - limit: the queue's bound, `ViewerQueue`'s default of 4 MiB unless a test
    ///     needs a smaller one.
    ///   - interval, now, schedule: `ResyncThrottle`'s, injectable for tests.
    package init(streamer: any ScreenStreaming, session: String, resize: ResizeMode,
                 greeting: StreamMessage?, limit: Int = 4 << 20,
                 interval: UInt64 = ResyncThrottle.defaultInterval,
                 now: @escaping ResyncThrottle.Clock = ResyncThrottle.systemClock,
                 schedule: @escaping ResyncThrottle.Scheduler = ResyncThrottle.systemScheduler) {
        // The queue and the throttle are built before `self` exists, and both have to
        // reach it. A weak box breaks the cycle: the queue keeps its overflow handler
        // for its whole life, and the viewer must not outlive its route because of it.
        let owner = WeakViewer()
        queue = ViewerQueue(limit: limit) { owner.viewer?.throttle.request() }
        throttle = ResyncThrottle(interval: interval, now: now, schedule: schedule) {
            owner.viewer?.resyncNow()
        }
        self.streamer = streamer
        owner.viewer = self

        if let greeting { queue.push(greeting) }
        let queue = self.queue
        let id = streamer.attach(session: session, resize: resize) { queue.push($0) }

        lock.lock()
        connectionId = id
        let held = resyncBeforeId && !closed
        resyncBeforeId = false
        lock.unlock()
        if held { askStreamer(id) }
    }

    /// Ends the viewer: no resync is asked for after this (a deferred one included),
    /// the streamer forgets it, and the queue is finished so its writer drains and
    /// stops. Safe to call more than once and from any exit path.
    package func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let id = connectionId
        lock.unlock()
        throttle.cancel()
        if let id { streamer.detach(connectionId: id) }
        queue.finish()
    }

    /// The viewer's claim of a grid, from its inbound `resize`: handed to the streamer
    /// with this viewer's id, which answers it with exactly one `resize` carrying
    /// `own: true`, through the queue. Nothing after `close()`.
    package func claim(cols: Int, rows: Int) {
        lock.lock()
        let id = closed ? nil : connectionId
        lock.unlock()
        guard let id else { return }
        streamer.claim(connectionId: id, cols: cols, rows: rows)
    }

    private func resyncNow() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        guard let id = connectionId else {
            resyncBeforeId = true
            lock.unlock()
            return
        }
        lock.unlock()
        askStreamer(id)
    }

    private func askStreamer(_ id: UUID) {
        let queue = self.queue
        streamer.resync(connectionId: id) { queue.resyncUnavailable() }
    }
}

private final class WeakViewer: @unchecked Sendable {
    weak var viewer: AttachedViewer?
}
