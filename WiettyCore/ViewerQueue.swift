import Foundation
import WiettyShared

/// What the server holds for one viewer between the stream hub and the socket writer,
/// bounded so a viewer that reads slower than the terminal writes cannot make the
/// server hold an unbounded backlog for it.
///
/// Only the payload of queued `data` and `repaint` messages counts against the limit.
/// When a push of either would take that count past the limit, the queue overflows:
/// every queued `data`, `repaint` and `snapshot` is dropped, the message being pushed
/// with them, and `onOverflow` asks for a fresh start. Until a `snapshot` arrives, any
/// further `data` and `repaint` are dropped too, because without the snapshot they
/// would apply to a screen the viewer no longer has.
///
/// A `snapshot` is never counted and never itself causes an overflow: it replaces
/// everything the viewer holds, so it is what an overflow is answered with. An overflow
/// while a snapshot is still queued drops that snapshot with the rest and asks again, so
/// the queue never holds more than the limit plus one snapshot. `resize`, `hello`,
/// `error` and `ended` are control messages: never counted, never dropped.
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
    private var finished = false
    /// The one consumer, parked in `next()` on an empty queue.
    private var waiter: CheckedContinuation<StreamMessage?, Never>?

    /// - Parameter onOverflow: called once per overflow, outside the queue's lock.
    ///   Whoever receives it answers by pushing a `resize` and a `snapshot`. It is not
    ///   called again while that answer is outstanding.
    package init(limit: Int = 4 << 20, onOverflow: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.onOverflow = onOverflow
    }

    /// Queues a message for the viewer. Ignored once the queue is finished.
    package func push(_ message: StreamMessage) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        var overflowed = false
        var accepted = true
        switch message {
        case let .data(bytes), let .repaint(bytes):
            if resyncPending {
                accepted = false
            } else if counted + bytes.count > limit {
                dropCountedAndSnapshotsLocked()
                resyncPending = true
                overflowed = true
                accepted = false
            } else {
                counted += bytes.count
            }
        case .snapshot:
            resyncPending = false
        case .hello, .error, .resize, .ended:
            break
        }
        if accepted { items.append(message) }
        // A parked consumer means the queue was empty, so what was just appended is
        // the front of it.
        var handOver: (CheckedContinuation<StreamMessage?, Never>, StreamMessage)?
        if accepted, let waiter, let front = popLocked() {
            self.waiter = nil
            handOver = (waiter, front)
        }
        lock.unlock()

        if let (waiter, front) = handOver { waiter.resume(returning: front) }
        if overflowed { onOverflow() }
    }

    /// The next message to write, or nil once finished and drained.
    ///
    /// One consumer at a time: the socket writer of this viewer. A second call while
    /// one is parked is a programming error and stops the process. The call is not
    /// cancellation aware; `finish()` is what releases a parked consumer.
    package func next() async -> StreamMessage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<StreamMessage?, Never>) in
            lock.lock()
            precondition(waiter == nil, "ViewerQueue.next() has one consumer at a time")
            if let front = popLocked() {
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
    }

    /// Ends the queue. Later pushes are ignored, `next()` still hands out what is
    /// queued and then returns nil, and a consumer parked on an empty queue gets nil.
    package func finish() {
        lock.lock()
        finished = true
        let parked = waiter
        waiter = nil
        lock.unlock()
        parked?.resume(returning: nil)
    }

    // MARK: Under the lock

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
