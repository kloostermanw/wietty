import Foundation
import WiettyShared

/// What the server holds for one viewer between the stream hub and the socket writer,
/// bounded so a viewer that reads slower than the terminal writes cannot make the
/// server hold an unbounded backlog for it.
///
/// Only the payload of queued `data` and `repaint` messages counts against the limit.
/// When a push of either would take that count past the limit, the queue overflows:
/// every queued `data`, `repaint` and `snapshot` is dropped, the message being pushed
/// with them, and `onOverflow` asks for a fresh start. A single `data` or `repaint`
/// larger than the limit overflows even an empty queue. Until a `snapshot` arrives, any
/// further `data` and `repaint` are dropped too, because without the snapshot they
/// would apply to a screen the viewer no longer has.
///
/// A `snapshot` is never counted and never itself causes an overflow: it replaces
/// everything the viewer holds, so it is what an overflow is answered with. An overflow
/// while a snapshot is still queued drops that snapshot with the rest and asks again, so
/// the queue holds at most the limit plus one snapshot (the writer may hold one more
/// message, the one it has taken and is sending). `resize`, `hello` and `error` are
/// control messages: never counted, never dropped.
///
/// `ended` is the last message. Pushed while a resync is pending it is held back, so
/// that the terminal's final screen reaches the viewer before it: it is queued behind
/// the next `snapshot`, or at once by `resyncUnavailable()` or `finish()`. Once an
/// `ended` is queued for delivery, every later push is ignored.
package final class ViewerQueue: @unchecked Sendable {
    private let limit: Int
    private let onOverflow: @Sendable () -> Void

    private let lock = NSLock()
    /// The queue is `items[head...]`. Taking from the front moves `head` rather than
    /// shifting the array, which is compacted once the taken part dominates it.
    private var items: [StreamMessage] = []
    private var head = 0
    /// The payload bytes of the queued `data` and `repaint` messages.
    private var counted = 0
    /// An overflow asked for a resync, and no `snapshot` has been pushed since.
    private var resyncPending = false
    /// An `ended` arrived while a resync was pending and waits for its outcome.
    private var endedHeld = false
    /// An `ended` is queued for delivery: nothing pushed after it is accepted.
    private var endedQueued = false
    private var finished = false
    /// The one consumer, parked in `next()` on an empty queue.
    private var waiter: CheckedContinuation<StreamMessage?, Never>?

    /// - Parameter onOverflow: called once per overflow, outside the queue's lock.
    ///   Whoever receives it answers by pushing a `resize` and a `snapshot`, or calls
    ///   `resyncUnavailable()` when no snapshot can come. It is not called again while
    ///   that answer is outstanding.
    package init(limit: Int = 4 << 20, onOverflow: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.onOverflow = onOverflow
    }

    /// Whether a consumer is parked in `next()`. Exists for tests, which wait for it
    /// instead of sleeping and hoping the consumer got there.
    package var hasParkedConsumer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiter != nil
    }

    /// Queues a message for the viewer. Ignored once the queue is finished or an
    /// `ended` is queued.
    package func push(_ message: StreamMessage) {
        lock.lock()
        guard !finished, !endedQueued else {
            lock.unlock()
            return
        }
        var overflowed = false
        switch message {
        case let .data(bytes), let .repaint(bytes):
            if resyncPending {
                break
            } else if counted + bytes.count > limit {
                dropCountedAndSnapshotsLocked()
                resyncPending = true
                overflowed = true
            } else {
                counted += bytes.count
                items.append(message)
            }
        case .snapshot:
            resyncPending = false
            items.append(message)
            releaseHeldEndedLocked()
        case .ended:
            if resyncPending {
                endedHeld = true
            } else {
                items.append(message)
                endedQueued = true
            }
        case .hello, .error, .resize:
            items.append(message)
        }
        let handOver = handOverLocked()
        lock.unlock()

        handOver?()
        if overflowed { onOverflow() }
    }

    /// The owner's answer to an overflow when no snapshot will come. Ends the pending
    /// resync and releases a held `ended`. Does nothing when no resync is pending.
    package func resyncUnavailable() {
        lock.lock()
        guard resyncPending else {
            lock.unlock()
            return
        }
        resyncPending = false
        releaseHeldEndedLocked()
        let handOver = handOverLocked()
        lock.unlock()
        handOver?()
    }

    /// The next message to write, or nil once finished and drained.
    ///
    /// One consumer at a time: the socket writer of this viewer. A second call while
    /// one is parked is a programming error and stops the process. A cancelled call
    /// returns nil, whether it was parked or cancelled before it began, and takes
    /// nothing from the queue; a later call from another task still gets what is queued.
    package func next() async -> StreamMessage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<StreamMessage?, Never>) in
                lock.lock()
                precondition(waiter == nil, "ViewerQueue.next() has one consumer at a time")
                // Checked under the lock: a cancel that lands before the consumer parks
                // finds no waiter in its handler, and is seen here instead.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else if let front = popLocked() {
                    lock.unlock()
                    continuation.resume(returning: front)
                } else if finished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let parked = waiter
            waiter = nil
            lock.unlock()
            parked?.resume(returning: nil)
        }
    }

    /// Ends the queue. Later pushes are ignored, a held `ended` is queued, `next()`
    /// still hands out what is queued and then returns nil, and a consumer parked on
    /// an empty queue gets the released `ended` or nil.
    package func finish() {
        lock.lock()
        finished = true
        releaseHeldEndedLocked()
        let handOver = handOverLocked()
        let parked = waiter
        waiter = nil
        lock.unlock()
        handOver?()
        parked?.resume(returning: nil)
    }

    // MARK: Under the lock

    /// Takes the parked consumer and the front of the queue together, so the caller can
    /// resume it after unlocking. A parked consumer means the queue was empty, so the
    /// front is what was just added.
    private func handOverLocked() -> (() -> Void)? {
        guard let parked = waiter, let front = popLocked() else { return nil }
        waiter = nil
        return { parked.resume(returning: front) }
    }

    private func releaseHeldEndedLocked() {
        guard endedHeld else { return }
        endedHeld = false
        items.append(.ended)
        endedQueued = true
    }

    private func popLocked() -> StreamMessage? {
        guard head < items.count else { return nil }
        let front = items[head]
        head += 1
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 1024 && head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        switch front {
        case let .data(bytes), let .repaint(bytes): counted -= bytes.count
        default: break
        }
        return front
    }

    /// Keeps only the control messages, in their order.
    private func dropCountedAndSnapshotsLocked() {
        items = items[head...].filter { message in
            switch message {
            case .data, .repaint, .snapshot: false
            case .hello, .error, .resize, .ended: true
            }
        }
        head = 0
        counted = 0
    }
}
