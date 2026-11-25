import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// Everything a viewer was sent, in the order it was sent. Lock guarded for the
/// reason every sink in this bundle is: the hub calls it from its own queue.
private final class ViewerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamMessage] = []
    func add(_ message: StreamMessage) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// What a viewer's own terminal ends up showing: the messages it was sent, played
/// into a fresh terminal exactly as a browser or an iPad plays them, a `resize`
/// setting the grid and a `snapshot`, a `repaint` or a `data` being written.
///
/// A real terminal rather than a scan of the bytes, because the claim under test
/// is about a screen. A paint is not a prefix of the stream: it is cursor
/// addressed, it carries modes, and whether it lines up with what follows can
/// only be read off the terminal both were written into.
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
        case let .snapshot(bytes), let .repaint(bytes), let .data(bytes):
            let target = try terminal ?? GhosttyVtTerminal(size: TerminalSize(cols: 80, rows: 24),
                                                           scrollbackLines: scrollbackLines)
            terminal = target
            target.write(bytes)
        case .ended, .hello, .error:
            break
        }
    }
    guard let terminal else { return [] }
    return terminal.text(maxLines: scrollbackLines * 2)
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
}

/// The first two messages of an attach: the grid, then a snapshot that starts
/// from a full reset, so whatever the viewer showed before is gone.
private func expectAnAttach(_ messages: [StreamMessage]) {
    guard messages.count >= 2, case .resize = messages[0],
          case let .snapshot(frame) = messages[1] else {
        Issue.record("an attach did not start with a resize and a snapshot")
        return
    }
    #expect(frame.starts(with: TerminalPaint.hardReset))
}

/// Why a run of lines is not "every number once, in order, ending at `last`", or
/// nil when it is. A sentence rather than a boolean, so a failure names the line
/// the join went wrong at.
private func faultInNumberedLines(_ lines: [String], endingAt last: Int,
                                  startingAt first: Int? = nil) -> String? {
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
    if let first, lines.first != String(first) {
        return "the lines start at \(lines[0]) and not at \(first)"
    }
    return previous == last ? nil : "the lines stop at \(previous ?? 0) and not at \(last)"
}

/// The join between a paint and the stream that follows it.
///
/// A paint taken from the screen model is exact, and an exact paint only helps if
/// the stream picks up at the very byte the paint stops at. One byte late and a
/// line is missing; one chunk early and a build log shows lines twice. The hub
/// makes the join by doing three things as one step under a session's lock:
/// taking what it has accepted, asking for the paint, and registering the viewer.
/// These tests race a writer against that step, because nothing but a race can
/// show it holds.
@Suite struct PaneStreamJoinTests {
    private static let session = "gt:join"

    /// A hub wired the way `GhosttyStack` wires it, on a model of its own.
    ///
    /// - Parameter parseDelay: microseconds each chunk takes to reach the model,
    ///   on top of the parse. A real parse is far too quick for a test to land an
    ///   attach inside it, and inside it is exactly where a hub that accepted a
    ///   chunk before the model had it would hand out a paint that is one chunk
    ///   short. Stretching it makes that window wide enough to hit every time.
    ///   - pacedClaims: a claim clock that paces every claim, so a test that races
    ///     claims against the stream has each one handled rather than held.
    private func wired(_ size: TerminalSize, parseDelay: UInt32 = 0,
                       pacedClaims: Bool = false) throws -> (hub: PaneStreamHub, model: GhosttyVtScreenModel) {
        let model = try GhosttyVtScreenModel(size: size)
        let hub = pacedClaims ? PaneStreamHub(startTimer: true, claimClock: ClaimTimers.paced())
                              : PaneStreamHub(startTimer: true)
        hub.onIngest = { _, bytes in
            if parseDelay > 0 { usleep(parseDelay) }
            model.write(bytes)
        }
        hub.onSnapshot = { _ in model.snapshotFrame() }
        hub.onRepaint = { _ in model.repaintFrame() }
        return (hub, model)
    }


    /// The output of `seq 1 count` as a pty hands it over, cut into chunks at
    /// arbitrary bytes, so numbers and line endings are split across writes.
    private static func chunks(upTo count: Int, using random: inout SystemRandomNumberGenerator) -> [[UInt8]] {
        let bytes = Array((1...count).map { "\($0)\r\n" }.joined().utf8)
        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            let length = min(Int.random(in: 1...96, using: &random), bytes.count - offset)
            chunks.append(Array(bytes[offset..<(offset + length)]))
            offset += length
        }
        return chunks
    }

    /// A viewer attaching while plain output streams sees every line exactly once.
    ///
    /// The writer runs on a thread of its own, as a terminal's relay queue is, and the
    /// flush timer runs, so at the moment of the attach there are bytes the model
    /// has parsed and the hub has not delivered: the state both old failures came
    /// from. Many rounds, each attaching at a different point, because one round
    /// proves nothing about a race. Every other round the model is slow to take a
    /// chunk, which is the round that catches a chunk delivered before it was
    /// parsed.
    @Test func aViewerAttachingMidStreamSeesEveryLineExactlyOnce() async throws {
        var random = SystemRandomNumberGenerator()
        let lines = 1_500
        for round in 0..<120 {
            let slowParse = round % 2 == 1
            let (hub, _) = try wired(TerminalSize(cols: 80, rows: 24), parseDelay: slowParse ? 150 : 0)
            let chunks = Self.chunks(upTo: lines, using: &random)
            // Anywhere from before the first chunk to just before the last.
            let attachAt = Int.random(in: 0..<chunks.count, using: &random)
            let session = Self.session
            let log = ViewerLog()

            let writer = Task.detached {
                for chunk in chunks {
                    hub.write(session: session, bytes: chunk)
                    // Slow enough, one way or the other, that a round spans
                    // several flushes.
                    if !slowParse { usleep(150) }
                }
            }
            let attacher = Task.detached {
                // Roughly the moment the writer reaches `attachAt`, without the two
                // being tied together by anything the hub could benefit from.
                usleep(UInt32(attachAt * 190))
                hub.attach(session: session, resize: .repaint) { log.add($0) }
            }
            await attacher.value
            await writer.value
            hub.flush()

            expectAnAttach(log.messages)
            // From the first line: the snapshot carries the history, so a viewer
            // attaching late has what scrolled past before it came.
            let shown = try replay(log.messages, scrollbackLines: 10_000)
            if let fault = faultInNumberedLines(shown, endingAt: lines, startingAt: 1) {
                Issue.record("round \(round), attached near chunk \(attachAt) of \(chunks.count): \(fault)")
                return
            }
            hub.stop()
        }
    }

    /// A repaint has the same join to make. The grid moves, the viewers already
    /// attached are painted again, and the bytes on either side of that paint
    /// must neither be shown twice nor lost. A viewer attached from the first
    /// byte has to end with every line, however many times it was repainted on
    /// the way.
    @Test func aRepaintMidStreamNeitherRepeatsNorDropsALine() async throws {
        var random = SystemRandomNumberGenerator()
        let lines = 1_500
        for round in 0..<40 {
            let (hub, model) = try wired(TerminalSize(cols: 80, rows: 24), pacedClaims: true)
            let chunks = Self.chunks(upTo: lines, using: &random)
            let session = Self.session
            let log = ViewerLog()
            hub.attach(session: session, resize: .repaint) { log.add($0) }
            expectAnAttach(log.messages)
            // Another viewer claims, and the claim resizes the model, as the
            // service's resizer does.
            hub.onClaim = { _, size in model.resize(to: size) }
            let claimer = hub.attach(session: session, resize: .reflow) { _ in }

            let writer = Task.detached {
                for chunk in chunks {
                    hub.write(session: session, bytes: chunk)
                    usleep(150)
                }
            }
            let resizer = Task.detached {
                var rows = 24
                while !Task.isCancelled {
                    rows = rows == 24 ? 31 : 24
                    hub.claim(connectionId: claimer, cols: 80, rows: rows)
                    try? await Task.sleep(for: .milliseconds(3))
                }
            }
            await writer.value
            resizer.cancel()
            await resizer.value
            hub.waitForPendingDeliveries()
            hub.flush()

            let shown = try replay(log.messages, scrollbackLines: 10_000)
            if let fault = faultInNumberedLines(shown, endingAt: lines, startingAt: 1) {
                Issue.record("round \(round): \(fault)")
                return
            }
            // And it really was repainted along the way, or this proved nothing.
            let paints = log.messages.filter { if case .repaint = $0 { true } else { false } }.count
            #expect(paints > 0, "round \(round) never repainted")
            hub.stop()
        }
    }

    /// A character split across the moment of an attach arrives whole. The model
    /// has only half of it, so the paint does not show it, and the hub must then
    /// hand the new viewer all of its bytes and not the second half alone.
    @Test func aCharacterSplitAcrossAnAttachArrivesWhole() throws {
        let (hub, _) = try wired(TerminalSize(cols: 40, rows: 6))
        defer { hub.stop() }
        let bytes = Array("caf\u{E9} \u{65E5}\u{672C}".utf8)
        // Inside the three bytes of the first CJK character.
        let cut = Array("caf\u{E9} ".utf8).count + 1
        let log = ViewerLog()
        hub.write(session: Self.session, bytes: Array(bytes[..<cut]))
        hub.attach(session: Self.session, resize: .repaint) { log.add($0) }
        hub.write(session: Self.session, bytes: Array(bytes[cut...]))
        hub.flush()
        #expect(try replay(log.messages, scrollbackLines: 100) == ["caf\u{E9} \u{65E5}\u{672C}"])
    }

    /// The viewers already watching get what was accepted before a newcomer's
    /// paint, and the newcomer does not get it a second time on top of that paint.
    @Test func whatWasAcceptedBeforeAnAttachGoesToEarlierViewersOnly() throws {
        let (hub, _) = try wired(TerminalSize(cols: 40, rows: 6))
        defer { hub.stop() }
        let early = ViewerLog()
        let late = ViewerLog()
        hub.attach(session: Self.session, resize: .repaint) { early.add($0) }
        let earlyPaint = early.messages.count
        hub.write(session: Self.session, bytes: Array("before\r\n".utf8))
        hub.attach(session: Self.session, resize: .reflow) { late.add($0) }
        hub.write(session: Self.session, bytes: Array("after\r\n".utf8))
        hub.flush()

        #expect(Array(early.messages.dropFirst(earlyPaint))
                == [.data(Array("before\r\n".utf8)), .data(Array("after\r\n".utf8))])
        // A size, a snapshot that already holds "before", then only what came after.
        expectAnAttach(late.messages)
        #expect(late.messages.count == 3)
        #expect(late.messages.last == .data(Array("after\r\n".utf8)))
        #expect(try replay(late.messages, scrollbackLines: 100) == ["before", "after"])
    }

    /// One terminal's parse must not hold up another terminal's viewers. A
    /// session's lock is held while its model takes a chunk, and a model that is
    /// reflowing a full scrollback after a resize can keep a write waiting for a
    /// long time. The flush timer skips a session it cannot lock and delivers
    /// everyone else's bytes; were it to wait, every viewer of every terminal
    /// would stall behind the one being resized.
    @Test func aSessionStuckInItsModelDoesNotStallAnotherSessionsViewers() async throws {
        let hub = PaneStreamHub(startTimer: true)
        defer { hub.stop() }
        let release = DispatchSemaphore(value: 0)
        let entered = ViewerLog()
        hub.onIngest = { session, _ in
            guard session == "gt:stuck" else { return }
            entered.add(.ended)
            release.wait()
        }
        let stuck = ViewerLog()
        let free = ViewerLog()
        hub.attach(session: "gt:stuck", resize: .repaint) { stuck.add($0) }
        hub.attach(session: "gt:free", resize: .repaint) { free.add($0) }

        let writer = Task.detached { hub.write(session: "gt:stuck", bytes: Array("held".utf8)) }
        while entered.messages.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        // Two writes a few ticks apart: a timer that waited on the stuck session
        // could still deliver the first on its way to getting parked, never the
        // second.
        hub.write(session: "gt:free", bytes: Array("one ".utf8))
        try await Task.sleep(for: .milliseconds(40))
        hub.write(session: "gt:free", bytes: Array("two".utf8))
        let deadline = ContinuousClock.now + .seconds(2)
        while free.messages.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(free.messages == [.data(Array("one ".utf8)), .data(Array("two".utf8))])
        #expect(stuck.messages.isEmpty)

        // And nothing of the stuck session was lost by being skipped.
        release.signal()
        await writer.value
        hub.flush()
        #expect(stuck.messages == [.data(Array("held".utf8))])
    }

    /// Every chunk the hub accepts is handed to the model's feed, against its own
    /// session and in order, whether or not anybody is watching.
    @Test func everyAcceptedChunkIsHandedToTheModelFeed() {
        final class Fed: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: [UInt8]] = [:]
            func add(_ session: String, _ bytes: [UInt8]) {
                lock.lock(); storage[session, default: []] += bytes; lock.unlock()
            }
            func bytes(_ session: String) -> [UInt8] {
                lock.lock(); defer { lock.unlock() }
                return storage[session] ?? []
            }
        }
        let hub = PaneStreamHub()
        let fed = Fed()
        hub.onIngest = { fed.add($0, $1) }
        hub.write(session: "gt:1", bytes: Array("one ".utf8))
        hub.write(session: "gt:2", bytes: Array("other".utf8))
        hub.write(session: "gt:1", bytes: Array("two".utf8))
        #expect(fed.bytes("gt:1") == Array("one two".utf8))
        #expect(fed.bytes("gt:2") == Array("other".utf8))
    }
}

/// The same join, end to end: a real shell printing into a real pty, through the
/// relay, the service and the hub as `GhosttyStack` wires them.
@MainActor
@Suite struct PaneStreamJoinEndToEndTests {
    @Test func aViewerAttachingToARunningCommandSeesEveryLineExactlyOnce() async throws {
        let lines = 12_000
        var attachedWhileRunning = 0
        for round in 0..<6 {
            let stack = GhosttyStack.testing(host: FakeSurfaceHost())
            defer { stack.shutDown() }
            let handle = try await stack.service.open(
                folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
                command: "i=0; while [ $i -lt \(lines) ]; do i=$((i+1)); echo $i; done", badge: nil)
            // A different point in the run each round, the first before the shell
            // has printed anything.
            try await Task.sleep(for: .milliseconds(round * 25))
            let log = ViewerLog()
            stack.hub.attach(session: handle.sessionId, resize: .repaint) { log.add($0) }
            let deadline = ContinuousClock.now + .seconds(20)
            while !log.messages.contains(.ended), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(log.messages.contains(.ended), "round \(round): the command never ended")
            // Attached after it had already exited: answered `ended` and nothing
            // else, which is the census doing its job and says nothing here.
            guard log.messages != [.ended] else { continue }
            attachedWhileRunning += 1
            expectAnAttach(log.messages)

            let shown = try replay(log.messages, scrollbackLines: 20_000)
            if let fault = faultInNumberedLines(shown, endingAt: lines) {
                Issue.record("round \(round): \(fault)")
                return
            }
        }
        #expect(attachedWhileRunning > 0)
    }
}
