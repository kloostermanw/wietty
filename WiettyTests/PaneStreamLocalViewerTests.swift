import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// The kernel's id of the calling thread, which is what tells "on the writer's
/// thread" from "on the delivery queue": a queue's work runs on some pool thread,
/// never on a thread the test started itself.
private func threadId() -> UInt64 {
    var id: UInt64 = 0
    pthread_threadid_np(nil, &id)
    return id
}

/// Everything a local viewer was sent, in order, with the thread each call came on.
/// Lock guarded: the hub calls `write` from the writer's thread and from its own
/// queue.
private final class LocalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(message: StreamMessage, thread: UInt64)] = []
    private var inside = 0
    private var overlaps = 0

    /// Records a message. `hold` is how long the call stays inside, in
    /// microseconds, as a surface that reads slowly would.
    func add(_ message: StreamMessage, hold: UInt32 = 0) {
        lock.lock()
        inside += 1
        if inside > 1 { overlaps += 1 }
        storage.append((message, threadId()))
        lock.unlock()
        if hold > 0 { usleep(hold) }
        lock.lock(); inside -= 1; lock.unlock()
    }
    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return storage.map(\.message) }
    var threads: [UInt64] { lock.lock(); defer { lock.unlock() }; return storage.map(\.thread) }
    /// How many calls began while another was still inside: two writes for one
    /// viewer at once.
    var overlapping: Int { lock.lock(); defer { lock.unlock() }; return overlaps }
    var dataBytes: [UInt8] { dataPayload(messages) }
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

private func dataPayload(_ messages: [StreamMessage]) -> [UInt8] {
    messages.flatMap { message -> [UInt8] in
        if case let .data(payload) = message { return payload }
        return []
    }
}

private func isData(_ message: StreamMessage) -> Bool {
    if case .data = message { return true }
    return false
}

/// Runs `body` on a thread of its own, as a terminal's relay does, and returns a
/// semaphore signalled when it returns.
private func onThread(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        body()
        done.signal()
    }
    return done
}

/// Polls `condition` until it holds or `seconds` pass. For waiting on something
/// that is expected to happen; never the proof that something did not.
private func eventually(within seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds > deadline { return false }
        usleep(1_000)
    }
    return true
}

/// The messages played into a fresh terminal, as a viewer plays them. See
/// `PaneStreamJoinTests` for why a terminal and not a scan of the bytes.
private func replay(_ messages: [StreamMessage], scrollbackLines: Int) throws -> [String] {
    var terminal: GhosttyVtTerminal?
    for message in messages {
        switch message {
        case let .resize(cols, rows, _):
            let size = TerminalSize(cols: cols, rows: rows)
            if let terminal {
                terminal.resize(to: size)
            } else {
                terminal = try GhosttyVtTerminal(size: size, scrollbackLines: scrollbackLines)
            }
        case let .snapshot(payload), let .repaint(payload), let .data(payload):
            let target = try terminal ?? GhosttyVtTerminal(size: TerminalSize(cols: 80, rows: 24),
                                                           scrollbackLines: scrollbackLines)
            terminal = target
            target.write(payload)
        case .ended, .hello, .error:
            break
        }
    }
    guard let terminal else { return [] }
    return terminal.text(maxLines: scrollbackLines * 2)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
}

private func faultInNumberedLines(_ lines: [String], endingAt last: Int, startingAt first: Int) -> String? {
    guard !lines.isEmpty else { return "the viewer shows no lines at all" }
    var previous: Int?
    for line in lines {
        guard let number = Int(line) else { return "a line that is not a number: \(line.debugDescription)" }
        if let previous {
            if number == previous { return "line \(number) appears twice" }
            if number < previous { return "line \(number) follows \(previous): a stretch was repeated" }
            if number > previous + 1 { return "lines \(previous + 1) to \(number - 1) are missing" }
        }
        previous = number
    }
    if lines.first != String(first) { return "the lines start at \(lines[0]) and not at \(first)" }
    return previous == last ? nil : "the lines stop at \(previous ?? 0) and not at \(last)"
}

/// The output of `seq 1 count`, cut into chunks at arbitrary bytes.
private func numberedChunks(upTo count: Int, using random: inout SystemRandomNumberGenerator) -> [[UInt8]] {
    let all = Array((1...count).map { "\($0)\r\n" }.joined().utf8)
    var chunks: [[UInt8]] = []
    var offset = 0
    while offset < all.count {
        let length = min(Int.random(in: 1...96, using: &random), all.count - offset)
        chunks.append(Array(all[offset..<(offset + length)]))
        offset += length
    }
    return chunks
}

/// The second kind of viewer: written to on the thread that writes the terminal's
/// output, with a call that may block, and never dropped. What the Mac's own pane
/// becomes once it reads the hub over a local socket.
@Suite struct PaneStreamLocalViewerTests {
    private static let session = "gt:local"

    private func wired(_ size: TerminalSize,
                       timer: Bool = false) throws -> (hub: PaneStreamHub, model: GhosttyVtScreenModel) {
        let model = try GhosttyVtScreenModel(size: size)
        let hub = PaneStreamHub(startTimer: timer)
        hub.onIngest = { _, chunk in model.write(chunk) }
        hub.onSnapshot = { _ in model.snapshotFrame() }
        hub.onRepaint = { _ in model.repaintFrame() }
        return (hub, model)
    }

    // MARK: - Attach and the byte path

    @Test func anAttachGivesALocalViewerTheGridThenTheSnapshot() throws {
        let (hub, _) = try wired(TerminalSize(cols: 40, rows: 6))
        defer { hub.stop() }
        hub.write(session: Self.session, bytes: bytes("hello\r\n"))
        let log = LocalLog()
        hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        let messages = log.messages
        try #require(messages.count == 2)
        #expect(messages[0] == .resize(cols: 40, rows: 6, own: false))
        guard case let .snapshot(frame) = messages[1] else {
            Issue.record("the second message is not a snapshot: \(messages[1])")
            return
        }
        #expect(frame.starts(with: TerminalPaint.hardReset))
        #expect(try replay(messages, scrollbackLines: 100) == ["hello"])
    }

    /// Output is written to a local viewer by the thread that wrote it into the hub,
    /// before that write returns: no 8 ms batch and no hop to the delivery queue.
    /// And nothing is left behind for the timer or scheduled for a quiet flush on
    /// its behalf, since a local viewer has been given every byte already.
    @Test func outputReachesALocalViewerOnTheWritersThreadAtOnce() {
        let hub = PaneStreamHub(startTimer: true)
        defer { hub.stop() }
        let log = LocalLog()
        hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        let writer = Box<UInt64>(0)
        let seenOnReturn = Box<[StreamMessage]>([])
        let done = onThread {
            writer.value = threadId()
            hub.write(session: Self.session, bytes: bytes("hello"))
            seenOnReturn.value = log.messages
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(seenOnReturn.value == [.data(bytes("hello"))])
        #expect(log.threads == [writer.value])
        #expect(hub.quietFlushes(session: Self.session) == 0)
        #expect(hub.bufferedBytes(session: Self.session) == 0)
    }

    /// The backpressure: while a local viewer's `write` blocks, the hub's write on
    /// that session does not return, and the thread reading the pty waits with it.
    /// Another session's writes are not held.
    @Test func whileALocalViewersWriteBlocksTheWriteIntoItsSessionDoesNotReturn() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        hub.attachLocal(session: Self.session, resize: .repaint) { message in
            guard isData(message) else { return }
            entered.signal()
            release.wait()
        }
        let returned = onThread { hub.write(session: Self.session, bytes: bytes("x")) }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        #expect(returned.wait(timeout: .now() + 0.2) == .timedOut, "the write returned while the viewer blocked")

        let other = onThread { hub.write(session: "gt:other", bytes: bytes("y")) }
        #expect(other.wait(timeout: .now() + 5) == .success, "another session's write was held")

        release.signal()
        #expect(returned.wait(timeout: .now() + 5) == .success, "the write did not return once unblocked")
    }

    /// The join of phase 2, for a local viewer: output written in a tight loop on a
    /// thread of its own while the viewer attaches. The viewer sees the grid, the
    /// snapshot and then only bytes, and plays them into exactly the lines written.
    @Test func aLocalViewerAttachingMidStreamSeesEveryLineExactlyOnce() async throws {
        var random = SystemRandomNumberGenerator()
        let lines = 1_500
        for round in 0..<60 {
            let (hub, _) = try wired(TerminalSize(cols: 80, rows: 24), timer: true)
            let chunks = numberedChunks(upTo: lines, using: &random)
            let attachAt = Int.random(in: 0..<chunks.count, using: &random)
            let session = Self.session
            let log = LocalLog()
            let writer = Task.detached {
                for chunk in chunks {
                    hub.write(session: session, bytes: chunk)
                    usleep(100)
                }
            }
            let attacher = Task.detached {
                usleep(UInt32(attachAt * 120))
                hub.attachLocal(session: session, resize: .repaint) { log.add($0) }
            }
            await attacher.value
            await writer.value

            let messages = log.messages
            guard messages.count >= 2, case .resize = messages[0], case .snapshot = messages[1],
                  messages.dropFirst(2).allSatisfy(isData) else {
                Issue.record("round \(round): not a resize, a snapshot and then only data")
                return
            }
            let shown = try replay(messages, scrollbackLines: 10_000)
            if let fault = faultInNumberedLines(shown, endingAt: lines, startingAt: 1) {
                Issue.record("round \(round), attached near chunk \(attachAt) of \(chunks.count): \(fault)")
                return
            }
            hub.stop()
        }
    }

    /// A grid that changes while output streams into a slow surface. The bytes
    /// written before each repaint reach the viewer ahead of it and none after it,
    /// so the viewer still plays into every line once; and a `resize` is never
    /// written while a `data` is still being written, since the two come from two
    /// threads.
    @Test func aGridChangeDuringOutputIsNeitherInterleavedNorOutOfOrder() async throws {
        var random = SystemRandomNumberGenerator()
        let lines = 1_200
        for round in 0..<12 {
            let (hub, model) = try wired(TerminalSize(cols: 80, rows: 24))
            let chunks = numberedChunks(upTo: lines, using: &random)
            let session = Self.session
            let log = LocalLog()
            // A surface that reads slowly, slowest for a paint, so the delivery queue
            // backs up with resizes while the writer keeps coming.
            hub.attachLocal(session: session, resize: .repaint) { message in
                switch message {
                case .data: log.add(message, hold: 50)
                default: log.add(message, hold: 600)
                }
            }
            let writer = Task.detached {
                for chunk in chunks {
                    hub.write(session: session, bytes: chunk)
                    usleep(50)
                }
            }
            let resizer = Task.detached {
                var rows = 24
                while !Task.isCancelled {
                    rows = rows == 24 ? 31 : 24
                    let size = TerminalSize(cols: 80, rows: rows)
                    model.resize(to: size)
                    hub.noteSize(session: session, size)
                    usleep(500)
                }
            }
            await writer.value
            resizer.cancel()
            await resizer.value
            hub.waitForPendingDeliveries()

            #expect(log.overlapping == 0, "round \(round): two writes for one viewer at once")
            let shown = try replay(log.messages, scrollbackLines: 10_000)
            if let fault = faultInNumberedLines(shown, endingAt: lines, startingAt: 1) {
                Issue.record("round \(round): \(fault)")
                return
            }
            let paints = log.messages.filter { if case .repaint = $0 { true } else { false } }.count
            #expect(paints > 0, "round \(round) never repainted")
            hub.stop()
        }
    }

    /// The bytes written before a grid change are written to the viewer ahead of
    /// its `resize`, deterministically.
    @Test func bytesWrittenBeforeAGridChangePrecedeItsResize() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let log = LocalLog()
        hub.attachLocal(session: Self.session, resize: .reflow) { log.add($0) }
        hub.write(session: Self.session, bytes: bytes("before"))
        hub.noteSize(session: Self.session, TerminalSize(cols: 90, rows: 20))
        hub.write(session: Self.session, bytes: bytes("after"))
        hub.waitForPendingDeliveries()
        let messages = log.messages
        let resize = messages.firstIndex(of: .resize(cols: 90, rows: 20, own: false))
        let before = messages.firstIndex(of: .data(bytes("before")))
        #expect(resize != nil && before != nil && before! < resize!)
        #expect(log.dataBytes == bytes("beforeafter"))
    }

    // MARK: - Never dropped, never resynchronised

    /// A local viewer is never resynchronised: attaching on the alternate screen
    /// does not put it in the set the alternate screen rule serves, and a resync
    /// asked for its id is answered "unavailable".
    @Test func aLocalViewerIsNeverResynchronised() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let asked = Box(0)
        hub.onSnapshot = { _ in
            TerminalSnapshotFrame(size: TerminalSize(cols: 80, rows: 24), bytes: bytes("ALT"), alternate: true)
        }
        hub.onAlternateScreen = { _ in
            asked.value += 1
            return false
        }
        let log = LocalLog()
        let id = hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        hub.write(session: Self.session, bytes: bytes("x"))
        hub.waitForPendingDeliveries()
        #expect(asked.value == 0)

        let unavailable = DispatchSemaphore(value: 0)
        hub.resync(connectionId: id) { unavailable.signal() }
        #expect(unavailable.wait(timeout: .now() + 5) == .success)
        hub.waitForPendingDeliveries()
        #expect(log.messages == [.resize(cols: 80, rows: 24, own: false),
                                 .snapshot(TerminalPaint.hardReset + bytes("ALT")), .data(bytes("x"))])
    }

    /// A queued viewer beside a local one on the same session: each gets every byte
    /// once, the local one per write and the queued one still batched.
    @Test func aQueuedViewerBesideALocalOneIsUntouched() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let local = LocalLog()
        let queued = LocalLog()
        hub.attach(session: Self.session, resize: .repaint) { queued.add($0) }
        hub.attachLocal(session: Self.session, resize: .repaint) { local.add($0) }
        for part in ["a", "b", "c", "d"] { hub.write(session: Self.session, bytes: bytes(part)) }
        hub.waitForPendingDeliveries()
        hub.flush()
        #expect(local.messages == ["a", "b", "c", "d"].map { .data(bytes($0)) })
        #expect(queued.dataBytes == bytes("abcd"))
        #expect(queued.messages.count < 4, "\(queued.messages.count) messages: not batched")
    }

    /// Several local viewers of one session each get every byte, in order.
    @Test func everyLocalViewerOfASessionGetsEveryByte() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let logs = (0..<3).map { _ in LocalLog() }
        for log in logs { hub.attachLocal(session: Self.session, resize: .reflow) { log.add($0) } }
        for part in ["one ", "two ", "three"] { hub.write(session: Self.session, bytes: bytes(part)) }
        for log in logs { #expect(log.dataBytes == bytes("one two three")) }
    }

    // MARK: - Ending and detaching

    /// The end of a session: the bytes written before it, then `ended`, and nothing
    /// after.
    @Test func anEndingFollowsTheLastBytesAndNothingFollowsIt() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let log = LocalLog()
        hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        hub.write(session: Self.session, bytes: bytes("tail"))
        hub.endViewers(ofSession: Self.session)
        hub.waitForPendingDeliveries()
        #expect(log.messages == [.data(bytes("tail")), .ended])
        hub.write(session: Self.session, bytes: bytes("late"))
        hub.noteSize(session: Self.session, TerminalSize(cols: 10, rows: 10))
        hub.waitForPendingDeliveries()
        #expect(log.messages == [.data(bytes("tail")), .ended])
    }

    @Test func nothingIsWrittenToALocalViewerAfterItsDetachReturned() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let log = LocalLog()
        let id = hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        hub.write(session: Self.session, bytes: bytes("seen"))
        hub.detach(connectionId: id)
        hub.write(session: Self.session, bytes: bytes("unseen"))
        hub.noteSize(session: Self.session, TerminalSize(cols: 10, rows: 10))
        hub.endViewers(ofSession: Self.session)
        hub.waitForPendingDeliveries()
        #expect(log.messages == [.data(bytes("seen"))])
    }

    /// The case the local socket server will meet: its client is gone while the
    /// writer is blocked inside that client's `write`, and the delivery queue is
    /// waiting behind it with a resize. `detach` returns anyway, and once the
    /// blocked write is let go nothing more is written, the resize included.
    @Test func aDetachWhileAWriteIsBlockedReturnsAndEndsTheViewer() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let log = LocalLog()
        let id = hub.attachLocal(session: Self.session, resize: .repaint) { message in
            log.add(message)
            guard isData(message) else { return }
            entered.signal()
            release.wait()
        }
        let writer = onThread { hub.write(session: Self.session, bytes: bytes("x")) }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        // Queued behind the blocked write: it holds the session's lock while it
        // waits for the viewer's write lock.
        hub.noteSize(session: Self.session, TerminalSize(cols: 90, rows: 20))
        let delivery = onThread { hub.waitForPendingDeliveries() }
        #expect(delivery.wait(timeout: .now() + 0.1) == .timedOut, "the resize did not wait for the blocked write")

        let detached = onThread { hub.detach(connectionId: id) }
        #expect(detached.wait(timeout: .now() + 5) == .success, "detach waited for the blocked write")

        release.signal()
        #expect(writer.wait(timeout: .now() + 5) == .success)
        #expect(delivery.wait(timeout: .now() + 5) == .success)
        hub.write(session: Self.session, bytes: bytes("y"))
        #expect(log.messages == [.data(bytes("x"))])
    }

    // MARK: - The hook, claims, other sessions

    @Test func theFirstLocalViewerOfASessionIsReportedOnceItHasItsSnapshot() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let timeline = Box<[String]>([])
        hub.onSnapshot = { _ in
            TerminalSnapshotFrame(size: TerminalSize(cols: 80, rows: 24), bytes: [], alternate: false)
        }
        hub.onLocalViewerAttached = { session in timeline.value.append("attached \(session)") }
        hub.attachLocal(session: Self.session, resize: .repaint) { message in
            switch message {
            case .resize: timeline.value.append("first resize")
            case .snapshot: timeline.value.append("first snapshot")
            default: break
            }
        }
        #expect(timeline.value == ["first resize", "first snapshot", "attached \(Self.session)"])
        hub.attachLocal(session: Self.session, resize: .repaint) { _ in }
        hub.attachLocal(session: "gt:other", resize: .repaint) { _ in }
        hub.waitForPendingDeliveries()
        #expect(timeline.value == ["first resize", "first snapshot", "attached \(Self.session)",
                                   "attached gt:other"])
    }

    /// The own pane will claim the grid: a local claimant is answered through its
    /// own write, `own` true, and a queued viewer of the same session is told the
    /// grid with `own` false. The grid in force is answered to the claimant alone.
    @Test func aLocalViewerCanClaimTheGrid() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let claimed = Box<[TerminalSize]>([])
        hub.onClaim = { _, size in claimed.value.append(size) }
        let local = LocalLog()
        let queued = LocalLog()
        let id = hub.attachLocal(session: Self.session, resize: .reflow) { local.add($0) }
        hub.attach(session: Self.session, resize: .reflow) { queued.add($0) }

        hub.claim(connectionId: id, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        #expect(claimed.value == [TerminalSize(cols: 100, rows: 30)])
        #expect(local.messages == [.resize(cols: 100, rows: 30, own: true)])
        #expect(queued.messages == [.resize(cols: 100, rows: 30, own: false)])

        hub.claim(connectionId: id, cols: 100, rows: 30)
        hub.waitForPendingDeliveries()
        #expect(claimed.value.count == 1)
        #expect(local.messages == [.resize(cols: 100, rows: 30, own: true),
                                   .resize(cols: 100, rows: 30, own: true)])
        #expect(queued.messages == [.resize(cols: 100, rows: 30, own: false)])
    }

    /// A local viewer blocked inside its write holds up its own session's writer and
    /// nothing else: a queued viewer of another session keeps receiving on the
    /// timer. A queued viewer of the same session catches up once it is let go.
    @Test func aBlockedLocalViewerDoesNotStallAnotherSessionsViewers() {
        let hub = PaneStreamHub(startTimer: true)
        defer { hub.stop() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        hub.attachLocal(session: Self.session, resize: .repaint) { message in
            guard isData(message) else { return }
            entered.signal()
            release.wait()
        }
        let sameSession = LocalLog()
        let otherSession = LocalLog()
        hub.attach(session: Self.session, resize: .repaint) { sameSession.add($0) }
        hub.attach(session: "gt:other", resize: .repaint) { otherSession.add($0) }

        let writer = onThread { hub.write(session: Self.session, bytes: bytes("held")) }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        hub.write(session: "gt:other", bytes: bytes("one "))
        #expect(eventually { otherSession.dataBytes == bytes("one ") })
        usleep(40_000)
        hub.write(session: "gt:other", bytes: bytes("two"))
        #expect(eventually { otherSession.dataBytes == bytes("one two") })

        release.signal()
        #expect(writer.wait(timeout: .now() + 5) == .success)
        #expect(eventually { sameSession.dataBytes == bytes("held") })
    }

    // MARK: - A character cut by an attach or a repaint

    /// A local viewer gets every byte, so after its snapshot it must be handed the
    /// started half of a character the model holds, and the rest arrives in the
    /// stream: the character arrives whole.
    @Test func aCharacterSplitAcrossALocalAttachArrivesWhole() throws {
        let (hub, _) = try wired(TerminalSize(cols: 40, rows: 6))
        defer { hub.stop() }
        let text = Array("caf\u{E9} \u{65E5}\u{672C}".utf8)
        let cut = Array("caf\u{E9} ".utf8).count + 1
        let log = LocalLog()
        hub.write(session: Self.session, bytes: Array(text[..<cut]))
        hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        hub.write(session: Self.session, bytes: Array(text[cut...]))
        #expect(log.messages.count == 3)
        #expect(try replay(log.messages, scrollbackLines: 100) == ["caf\u{E9} \u{65E5}\u{672C}"])
    }

    /// The same across a repaint: the viewer was already given the first half in
    /// the stream, the repaint's reset throws it away with the old screen, the
    /// half goes behind the paint again, and the rest completes it.
    @Test func aCharacterSplitAcrossARepaintArrivesWhole() throws {
        let (hub, model) = try wired(TerminalSize(cols: 40, rows: 6))
        defer { hub.stop() }
        let text = Array("caf\u{E9} \u{65E5}\u{672C}".utf8)
        let cut = Array("caf\u{E9} ".utf8).count + 1
        let log = LocalLog()
        hub.attachLocal(session: Self.session, resize: .repaint) { log.add($0) }
        hub.write(session: Self.session, bytes: Array(text[..<cut]))
        let size = TerminalSize(cols: 50, rows: 8)
        model.resize(to: size)
        hub.noteSize(session: Self.session, size)
        hub.waitForPendingDeliveries()
        hub.write(session: Self.session, bytes: Array(text[cut...]))
        let paints = log.messages.compactMap { message -> [UInt8]? in
            if case let .repaint(payload) = message { return payload }
            return nil
        }
        try #require(paints.count == 1)
        #expect(Array(paints[0].suffix(1)) == [text[cut - 1]])
        #expect(try replay(log.messages, scrollbackLines: 100) == ["caf\u{E9} \u{65E5}\u{672C}"])
    }

    // MARK: - Carried from part 1: the timer and the size of a message

    /// A session whose lock is busy in back to back bursts, as a writer parsing a
    /// flood holds it, is still flushed while the bursts go on. The timer gives up
    /// on a busy session for a tick or two, but not for ever.
    @Test func aSessionBusyInBurstsIsStillFlushedWhileItIsBusy() {
        let hub = PaneStreamHub(startTimer: true)
        defer { hub.stop() }
        hub.onIngest = { _, _ in
            let end = DispatchTime.now().uptimeNanoseconds + 2_000_000
            while DispatchTime.now().uptimeNanoseconds < end {}
        }
        let writing = Box(true)
        let duringBursts = Box(0)
        hub.attach(session: "gt:busy", resize: .repaint) { message in
            if isData(message), writing.value { duringBursts.value += 1 }
        }
        let writer = onThread {
            let end = DispatchTime.now().uptimeNanoseconds + 600_000_000
            while DispatchTime.now().uptimeNanoseconds < end {
                hub.write(session: "gt:busy", bytes: bytes("x"))
            }
            writing.value = false
        }
        #expect(writer.wait(timeout: .now() + 10) == .success)
        #expect(duringBursts.value > 0, "the session was not flushed once in 600 ms of bursts")
    }

    /// One `data` message for a queued viewer holds at most 256 KiB: a larger take
    /// is delivered as several messages, in order. On a flush and on an ending.
    @Test func noDataMessageForAQueuedViewerExceeds256KiB() {
        let hub = PaneStreamHub()
        defer { hub.stop() }
        let log = LocalLog()
        hub.attach(session: Self.session, resize: .repaint) { log.add($0) }
        let large = (0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251) }
        hub.write(session: Self.session, bytes: large)
        hub.waitForPendingDeliveries()
        hub.flush()
        hub.write(session: Self.session, bytes: large)
        hub.endViewers(ofSession: Self.session)
        hub.waitForPendingDeliveries()

        let messages = log.messages
        #expect(messages.last == .ended)
        let sizes = messages.compactMap { message -> Int? in
            if case let .data(payload) = message { return payload.count }
            return nil
        }
        #expect(sizes.allSatisfy { $0 <= 256 * 1024 }, "\(sizes)")
        #expect(sizes.count >= 6, "\(sizes)")
        #expect(log.dataBytes == large + large)
    }
}
