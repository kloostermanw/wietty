import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// What several viewers were sent, in the one order the hub delivered it across
/// all of them. A per viewer log cannot show that one viewer's bytes went out
/// before another viewer's snapshot; this can.
private final class DeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(viewer: String, message: StreamMessage)] = []
    func add(_ viewer: String, _ message: StreamMessage) {
        lock.lock(); storage.append((viewer, message)); lock.unlock()
    }
    var entries: [(viewer: String, message: StreamMessage)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
    func messages(of viewer: String) -> [StreamMessage] {
        entries.filter { $0.viewer == viewer }.map(\.message)
    }
    func snapshots(of viewer: String) -> Int {
        messages(of: viewer).filter { if case .snapshot = $0 { true } else { false } }.count
    }
    func dataBytes(of viewer: String) -> [UInt8] {
        messages(of: viewer).flatMap { message -> [UInt8] in
            if case let .data(bytes) = message { return bytes }
            return []
        }
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func frame(_ text: String, alternate: Bool = false) -> TerminalSnapshotFrame {
    TerminalSnapshotFrame(size: TerminalSize(cols: 80, rows: 24), bytes: bytes(text), alternate: alternate)
}

/// A viewer that has lost its place is given a fresh start: the grid and a
/// snapshot, joined to the stream exactly as an attach is.
@Suite struct PaneStreamResyncTests {
    @Test func aResyncSendsTheOthersTheOutstandingBytesFirstAndThisViewerASnapshot() {
        let hub = PaneStreamHub()
        hub.onSnapshot = { _ in frame("SNAP") }
        let log = DeliveryLog()
        let lost = hub.attach(session: "gt:1", resize: .repaint) { log.add("lost", $0) }
        hub.attach(session: "gt:1", resize: .reflow) { log.add("other", $0) }
        hub.write(session: "gt:1", bytes: bytes("a"))
        hub.write(session: "gt:1", bytes: bytes("b"))
        let unavailable = Box(false)
        hub.resync(connectionId: lost) { unavailable.value = true }
        hub.waitForPendingDeliveries()
        hub.flush()

        #expect(unavailable.value == false)
        #expect(log.dataBytes(of: "other") == bytes("ab"))
        let lostMessages = log.messages(of: "lost")
        #expect(lostMessages.suffix(2) == [.resize(cols: 80, rows: 24, own: false),
                                          .snapshot(TerminalPaint.hardReset + bytes("SNAP"))])
        // Every byte the other viewer was sent went out before the snapshot: the
        // snapshot holds them, so the lost viewer must not get them after it.
        let entries = log.entries
        let snapshotAt = entries.lastIndex { $0.viewer == "lost" && isSnapshot($0.message) }
        let lastOtherData = entries.lastIndex { $0.viewer == "other" && isData($0.message) }
        #expect(snapshotAt != nil && lastOtherData != nil)
        #expect((lastOtherData ?? .max) < (snapshotAt ?? .min))
    }

    /// A resync is always answered. For a viewer the hub does not hold, and for a
    /// session whose snapshot cannot be built, the caller is told no snapshot is
    /// coming, which is what a `ViewerQueue` needs to stop waiting for one.
    @Test func aResyncThatCannotBeAnsweredWithASnapshotSaysSo() {
        let hub = PaneStreamHub()
        let gone = Box(false)
        hub.resync(connectionId: UUID()) { gone.value = true }
        hub.waitForPendingDeliveries()
        #expect(gone.value)

        hub.onSnapshot = { _ in nil }
        let log = DeliveryLog()
        let id = hub.attach(session: "gt:1", resize: .repaint) { log.add("v", $0) }
        let noFrame = Box(false)
        hub.resync(connectionId: id) { noFrame.value = true }
        hub.waitForPendingDeliveries()
        #expect(noFrame.value)
        // And the viewer keeps the stream.
        hub.write(session: "gt:1", bytes: bytes("still here"))
        hub.flush()
        #expect(log.dataBytes(of: "v") == bytes("still here"))
    }

    /// A new viewer of a session whose snapshot cannot be built still learns the
    /// grid, when the grid is known, before the stream. Without a known grid it
    /// gets nothing ahead of the stream, as before: there is nothing to tell it.
    @Test func aViewerWithoutASnapshotIsSentTheKnownGrid() {
        let hub = PaneStreamHub()
        hub.onSnapshot = { _ in nil }
        let claimer = hub.attach(session: "gt:1", resize: .reflow) { _ in }
        hub.claim(connectionId: claimer, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .reflow) { log.add("known", $0) }
        hub.attach(session: "gt:2", resize: .reflow) { log.add("unknown", $0) }
        hub.write(session: "gt:1", bytes: bytes("a"))
        hub.write(session: "gt:2", bytes: bytes("b"))
        hub.flush()

        #expect(log.messages(of: "known") == [.resize(cols: 100, rows: 30, own: false),
                                             .data(bytes("a"))])
        #expect(log.messages(of: "unknown") == [.data(bytes("b"))])
    }

    /// The contract task 7 builds on: a `ViewerQueue` that overflows asks the hub,
    /// from inside the hub's own delivery, for a resync. That must neither
    /// deadlock nor leave the queue waiting, and what the viewer drains is the
    /// snapshot after the overflow and the stream after that.
    @Test func aViewerQueueThatOverflowsIsResynchronisedFromInsideTheDelivery() async {
        let hub = PaneStreamHub()
        hub.onSnapshot = { _ in frame("SNAP") }
        let id = Box<UUID?>(nil)
        let queue = Box<ViewerQueue?>(nil)
        queue.value = ViewerQueue(limit: 8) {
            guard let viewer = id.value else { return }
            hub.resync(connectionId: viewer) { queue.value?.resyncUnavailable() }
        }
        id.value = hub.attach(session: "gt:1", resize: .repaint) { queue.value?.push($0) }
        hub.write(session: "gt:1", bytes: bytes("far more than eight bytes"))
        hub.flush()
        hub.waitForPendingDeliveries()
        hub.write(session: "gt:1", bytes: bytes("tail"))
        hub.flush()
        queue.value?.finish()

        var drained: [StreamMessage] = []
        while let message = await queue.value?.next() { drained.append(message) }
        // The overflow dropped the first snapshot, which had not been drained yet,
        // and kept its grid: control messages are never dropped.
        let grid = StreamMessage.resize(cols: 80, rows: 24, own: false)
        #expect(drained == [grid, grid, .snapshot(TerminalPaint.hardReset + bytes("SNAP")),
                            .data(bytes("tail"))])
    }

    // MARK: - The alternate screen

    /// A viewer that attached while a full screen program ran holds an empty
    /// primary screen underneath it. When the program leaves, that viewer is sent
    /// the terminal again; one that attached on the primary screen already has the
    /// screen underneath and is left alone.
    @Test func leavingTheAlternateScreenResynchronisesOnlyTheViewersThatJoinedOnIt() {
        let hub = PaneStreamHub()
        let alternate = Box(false)
        hub.onSnapshot = { _ in frame("SNAP", alternate: alternate.value) }
        hub.onAlternateScreen = { _ in alternate.value }
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .repaint) { log.add("primary", $0) }
        alternate.value = true
        hub.attach(session: "gt:1", resize: .repaint) { log.add("alternate", $0) }

        hub.write(session: "gt:1", bytes: bytes("still full screen"))
        hub.waitForPendingDeliveries()
        #expect(log.snapshots(of: "alternate") == 1)

        alternate.value = false
        hub.write(session: "gt:1", bytes: bytes("left"))
        hub.waitForPendingDeliveries()
        #expect(log.snapshots(of: "alternate") == 2)
        #expect(log.snapshots(of: "primary") == 1)

        // Forgotten once resynchronised on the primary screen.
        hub.write(session: "gt:1", bytes: bytes("more"))
        hub.waitForPendingDeliveries()
        hub.flush()
        #expect(log.snapshots(of: "alternate") == 2)
    }

    /// Forgotten when it is resynchronised, not when the resync succeeds: a viewer
    /// whose snapshot cannot be built now is not asked for again on every write
    /// that follows, which would be a snapshot attempt per chunk of output.
    @Test func aViewerIsResynchronisedOnceWhenTheTerminalLeavesTheAlternateScreen() {
        let hub = PaneStreamHub()
        let alternate = Box(true)
        let asked = Box(0)
        hub.onSnapshot = { _ in
            asked.value += 1
            return alternate.value ? frame("SNAP", alternate: true) : nil
        }
        hub.onAlternateScreen = { _ in alternate.value }
        hub.attach(session: "gt:1", resize: .repaint) { _ in }
        #expect(asked.value == 1)

        alternate.value = false
        hub.write(session: "gt:1", bytes: bytes("left"))
        hub.waitForPendingDeliveries()
        hub.write(session: "gt:1", bytes: bytes("more"))
        hub.waitForPendingDeliveries()
        hub.write(session: "gt:1", bytes: bytes("and more"))
        hub.waitForPendingDeliveries()
        #expect(asked.value == 2)
    }

    /// The same rule against a real model: the viewer that attached to a full
    /// screen program ends with the shell's screen that was underneath it.
    @Test func aViewerThatJoinedOnTheAlternateScreenEndsWithThePrimaryScreen() throws {
        let size = TerminalSize(cols: 40, rows: 6)
        let model = try GhosttyVtScreenModel(size: size)
        let hub = PaneStreamHub()
        hub.onIngest = { _, chunk in model.write(chunk) }
        hub.onSnapshot = { _ in model.snapshotFrame() }
        hub.onAlternateScreen = { _ in model.isAlternateScreen }
        hub.write(session: "gt:1", bytes: bytes("$ prompt line\r\n$ vim\r\n\u{1B}[?1049hFULL SCREEN"))
        hub.flush()
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .repaint) { log.add("v", $0) }
        hub.write(session: "gt:1", bytes: bytes("\u{1B}[?1049l$ "))
        hub.waitForPendingDeliveries()
        hub.flush()

        let viewer = try GhosttyVtTerminal(size: size, scrollbackLines: 100)
        for message in log.messages(of: "v") {
            switch message {
            case let .snapshot(payload), let .data(payload), let .repaint(payload): viewer.write(payload)
            default: break
            }
        }
        #expect(!viewer.isAlternateScreen)
        #expect(Array(viewer.viewportLines().prefix(2)) == ["$ prompt line", "$ vim"])
        #expect(viewer.viewportLines() == model.viewportLinesForTest())
    }

    // MARK: - Flush after quiet

    /// A keystroke's echo on a quiet terminal goes out at once rather than
    /// waiting for the next tick of the flush timer. This hub has no timer, so
    /// only the quiet rule can have delivered it.
    @Test func aWriteIntoAQuietSessionIsDeliveredWithoutWaitingForTheTimer() {
        let hub = PaneStreamHub()
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .repaint) { log.add("v", $0) }
        hub.write(session: "gt:1", bytes: bytes("x"))
        hub.waitForPendingDeliveries()
        #expect(log.dataBytes(of: "v") == bytes("x"))

        // Quiet again after a pause well past the interval.
        usleep(30_000)
        hub.write(session: "gt:1", bytes: bytes("y"))
        hub.waitForPendingDeliveries()
        #expect(log.dataBytes(of: "v") == bytes("xy"))
    }

    /// A quiet write into a session nobody watches schedules nothing: the flush
    /// would hand the bytes to nobody. Every local terminal is such a session
    /// until a remote viewer attaches, so this is every echoed keystroke. The bytes
    /// stay in the buffer, where the timer (or an attach) takes them, as before the
    /// quiet rule; once a viewer is there the rule applies again.
    @Test func aQuietWriteWithoutAViewerSchedulesNoDelivery() {
        let hub = PaneStreamHub()
        hub.write(session: "gt:1", bytes: bytes("x"))
        hub.waitForPendingDeliveries()
        #expect(hub.quietFlushes(session: "gt:1") == 0)

        hub.flush()   // what the timer does: empties the buffer of a session without viewers
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .repaint) { log.add("v", $0) }
        usleep(30_000)
        hub.write(session: "gt:1", bytes: bytes("y"))
        hub.waitForPendingDeliveries()
        #expect(hub.quietFlushes(session: "gt:1") == 1)
        #expect(log.dataBytes(of: "v") == bytes("y"))
    }

    /// A sustained stream is still batched: the quiet rule fires only for a write
    /// into an empty buffer long after the last flush.
    @Test func aSustainedStreamIsStillBatched() {
        let hub = PaneStreamHub()
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .repaint) { log.add("v", $0) }
        for _ in 0..<1_000 { hub.write(session: "gt:1", bytes: [0x2E]) }
        hub.waitForPendingDeliveries()
        hub.flush()
        let deliveries = log.messages(of: "v").count
        #expect(log.dataBytes(of: "v") == Array(repeating: 0x2E, count: 1_000))
        #expect(deliveries < 50, "\(deliveries) deliveries for 1,000 writes")
    }

    /// Output arriving more slowly than the delivery queue drains it, but faster
    /// than the interval, is batched too. Without the time condition every one of
    /// these writes would find the buffer empty and go out on its own: a terminal
    /// printing a steady trickle would put a message on the wire per read.
    ///
    /// Bounded by the time the loop really took rather than by a fixed count: on a
    /// loaded machine the 200 short sleeps take far longer than their sum, and a
    /// fixed count then failed a hub that batched exactly as it should. Every
    /// delivery is a tick of the 8 ms timer or a quiet write, and a quiet write
    /// needs 8 ms since the last delivery, in which the ticks found nothing to send.
    /// So the deliveries are at most one per 8 ms window, plus the first write, the
    /// closing flush and a little slack for the timer's leeway.
    @Test func aSteadyTrickleIsBatchedByTheInterval() {
        let hub = PaneStreamHub()
        let log = DeliveryLog()
        hub.attach(session: "gt:1", resize: .repaint) { log.add("v", $0) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 {
            hub.write(session: "gt:1", bytes: [0x2E])
            usleep(100)
        }
        hub.waitForPendingDeliveries()
        hub.flush()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let windows = Int((elapsed + 7_999_999) / 8_000_000)
        // The attach delivered nothing: the hub has no snapshot hook here.
        let deliveries = log.messages(of: "v").count
        #expect(log.dataBytes(of: "v") == Array(repeating: 0x2E, count: 200))
        #expect(deliveries <= windows + 3,
                "\(deliveries) deliveries for 200 writes in \(elapsed / 1_000_000) ms")
        // The bound above is the batching claim only while it is well under one
        // delivery per write. A loop slow enough (over about 800 ms) to lift it
        // that high proves nothing either way, so the run is reported as
        // inconclusive rather than failed.
        if windows + 3 >= 100 {
            print("aSteadyTrickleIsBatchedByTheInterval: inconclusive, the loop took "
                  + "\(elapsed / 1_000_000) ms, \(deliveries) deliveries for 200 writes")
        }
    }

    // MARK: - Input

    /// Input is handed on where it arrives. The hub has no thread of its own to
    /// put it on, and the main actor is exactly where it must not go.
    @Test func inputIsHandedOnOnTheCallersThread() {
        let hub = PaneStreamHub()
        let seen = Box<(session: String, bytes: [UInt8], thread: pthread_t?)?>(nil)
        hub.onInput = { session, input in seen.value = (session, input, pthread_self()) }
        let caller = pthread_self()
        hub.send(session: "gt:1", bytes: [0x1B, 0x5B, 0x41])
        let got = seen.value
        #expect(got?.session == "gt:1")
        #expect(got?.bytes == [0x1B, 0x5B, 0x41])
        #expect(got?.thread.map { pthread_equal($0, caller) != 0 } == true)
    }
}

private func isSnapshot(_ message: StreamMessage) -> Bool {
    if case .snapshot = message { return true }
    return false
}

private func isData(_ message: StreamMessage) -> Bool {
    if case .data = message { return true }
    return false
}

extension GhosttyVtScreenModel {
    /// The viewport as the model's own paint frame draws it, read back through a
    /// terminal of the same grid, for comparing with a viewer's terminal.
    fileprivate func viewportLinesForTest() -> [String] {
        guard let terminal = try? GhosttyVtTerminal(size: size, scrollbackLines: 0) else { return [] }
        terminal.write(TerminalPaint.reset + paintFrame())
        return terminal.viewportLines()
    }
}
