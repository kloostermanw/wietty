import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// A link the test drives: `deliver` and `end` call the bridge's callbacks on the
/// calling thread, as a link's own thread would.
private final class FakeLink: TerminalStreamLink, @unchecked Sendable {
    private let lock = NSLock()
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var startCount = 0
    private var stopCount = 0
    private var sent: [[UInt8]] = []
    private var claimed: [[Int]] = []
    private var stopGate: DispatchSemaphore?

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return messageHandler }
        set { lock.lock(); messageHandler = newValue; lock.unlock() }
    }
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return endHandler }
        set { lock.lock(); endHandler = newValue; lock.unlock() }
    }

    var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    var sends: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return sent }
    var claims: [[Int]] { lock.lock(); defer { lock.unlock() }; return claimed }

    func start() { lock.lock(); startCount += 1; lock.unlock() }
    func stop() {
        lock.lock(); stopCount += 1; let gate = stopGate; lock.unlock()
        _ = gate?.wait(timeout: .now() + 10)
    }
    /// From now on `stop()` waits on `gate` (at most ten seconds), as a real link's
    /// does for a callback blocked on the helper.
    func blockStop(on gate: DispatchSemaphore) { lock.lock(); stopGate = gate; lock.unlock() }
    func send(_ bytes: [UInt8]) { lock.lock(); sent.append(bytes); lock.unlock() }
    func claim(cols: Int, rows: Int) { lock.lock(); claimed.append([cols, rows]); lock.unlock() }

    func deliver(_ message: StreamMessage) { onMessage?(message) }
    func end(_ reason: TerminalEndReason) { onEnded?(reason) }
}

private final class BridgeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var resizeList: [[Int]] = []
    private var endList: [TerminalEndReason] = []
    private var goneCount = 0
    var gone: Int { lock.lock(); defer { lock.unlock() }; return goneCount }
    var resizes: [[Int]] { lock.lock(); defer { lock.unlock() }; return resizeList }
    var ends: [TerminalEndReason] { lock.lock(); defer { lock.unlock() }; return endList }

    func attach(to bridge: TerminalBridge) {
        bridge.onResize = { [self] cols, rows, own in
            lock.lock(); resizeList.append([cols, rows, own ? 1 : 0]); lock.unlock()
        }
        bridge.onEnded = { [self] reason in
            lock.lock(); endList.append(reason); lock.unlock()
        }
        bridge.onHelperGone = { [self] in
            lock.lock(); goneCount += 1; lock.unlock()
        }
    }
}

/// The bridge between a surface's `wietty-pty` and a terminal's stream, with a fake
/// link and a plain socket standing in for the helper, plus one run of the whole
/// path with the real server, link and helper.
@Suite struct TerminalBridgeTests {
    private func option(_ fd: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, name, &value, &length)
        return value
    }

    /// A bridge with a helper connected, and its link started.
    private func connected(_ link: FakeLink) throws -> (TerminalBridge, UnixTestSocket) {
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        #expect(waitUntil { link.starts == 1 })
        return (bridge, helper)
    }

    @Test func theLinkStartsOnlyOnceTheHelperHasConnected() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        defer { bridge.stop() }
        #expect(link.starts == 0)
        // Nothing is held for a surface that is not reading yet.
        Thread.sleep(forTimeInterval: 0.1)
        #expect(link.starts == 0)
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        defer { helper.close() }
        #expect(waitUntil { link.starts == 1 })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(link.starts == 1)
    }

    @Test func payloadsReachTheHelperUnchangedAndInOrder() throws {
        let link = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(link)
        events.attach(to: bridge)
        defer { bridge.stop() }
        let snapshot: [UInt8] = [0x1B, 0x63, 0xFF, 0xFE]
        let data: [UInt8] = [0xC3, 0x28, 0x00, 0x80]
        let repaint: [UInt8] = [0x1B, 0x5B, 0x48, 0xED, 0xA0, 0x80]
        link.deliver(.snapshot(snapshot))
        link.deliver(.resize(cols: 100, rows: 30, own: true))
        link.deliver(.data(data))
        link.deliver(.repaint(repaint))
        let expected = snapshot + data + repaint
        #expect(helper.read(expected.count) == expected)
        // The resize went to `onResize` and nothing else to the helper.
        #expect(staysSilent(helper.fd, for: 0.1))
        #expect(events.resizes == [[100, 30, 1]])
    }

    @Test func bytesFromTheHelperGoToTheLinkUnchanged() throws {
        let link = FakeLink()
        let (bridge, helper) = try connected(link)
        defer { bridge.stop() }
        let bytes: [UInt8] = [0xFF, 0x00, 0x80, 0x1B, 0x5B, 0x41]
        helper.write(bytes)
        #expect(waitUntil { link.sends.joined().count == bytes.count })
        #expect(Array(link.sends.joined()) == bytes)
    }

    /// The bridge holds nothing: while the helper is not reading, its write blocks,
    /// and so does the link's `onMessage` that made it. Shown by far more output
    /// than the socket holds, which is not all delivered until the helper reads.
    @Test func aHelperThatStopsReadingBlocksTheLink() throws {
        let link = FakeLink()
        let (bridge, helper) = try connected(link)
        defer { bridge.stop() }
        let chunk = (0..<(64 << 10)).map { UInt8(truncatingIfNeeded: $0) }
        let count = 64   // 4 MiB
        let returned = Counter()
        let delivery = BackgroundCall {
            for _ in 0..<count {
                link.deliver(.data(chunk))
                returned.increment()
            }
        }
        #expect(!delivery.wait(1))
        #expect(returned.value < count)

        let total = chunk.count * count
        let received = helper.read(total, within: 20)
        #expect(received.count == total)
        #expect(received == Array([[UInt8]](repeating: chunk, count: count).joined()))
        #expect(delivery.wait())
    }

    @Test func theLinksEndIsReportedAndKeepsTheHelper() throws {
        let link = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(link)
        events.attach(to: bridge)
        defer { bridge.stop() }
        link.end(.connectionLost)
        #expect(events.ends == [.connectionLost])
        #expect(staysSilent(helper.fd, for: 0.2))
        #expect(link.stops == 0)
    }

    @Test func aHelperThatDisconnectsStopsTheLink() throws {
        let link = FakeLink()
        let (bridge, helper) = try connected(link)
        defer { bridge.stop() }
        helper.close()
        #expect(waitUntil { link.stops == 1 })
    }

    /// The server answers every claim once and the owner counts the answers, so the
    /// claims made before the link starts are all sent, in order, not folded.
    @Test func everyClaimBeforeTheLinkStartsIsSentInOrderWhenItStarts() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        defer { bridge.stop() }
        bridge.claim(cols: 90, rows: 20)
        bridge.claim(cols: 100, rows: 30)
        bridge.claim(cols: 90, rows: 20)
        #expect(link.claims.isEmpty)
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        defer { helper.close() }
        #expect(waitUntil { link.claims.count == 3 })
        #expect(link.claims == [[90, 20], [100, 30], [90, 20]])
        bridge.claim(cols: 120, rows: 40)
        #expect(link.claims == [[90, 20], [100, 30], [90, 20], [120, 40]])
    }

    @Test func atMost4096EarlyClaimsAreKeptTheNewest() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        defer { bridge.stop() }
        #expect(TerminalBridge.maxPendingClaims == 4096)
        for cols in 1...4100 { #expect(bridge.claim(cols: cols, rows: 10)) }
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        defer { helper.close() }
        #expect(waitUntil { link.claims.count == 4096 })
        #expect(link.claims == (5...4100).map { [$0, 10] })
    }

    /// The hub ignores a grid outside 1...10,000 without an answer, so the bridge
    /// refuses it and says so: the owner counts only a claim that was accepted.
    @Test func aClaimOutsideTheHubsRangeIsRefused() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        #expect(!bridge.claim(cols: 0, rows: 24))
        #expect(!bridge.claim(cols: 80, rows: 0))
        #expect(!bridge.claim(cols: 10_001, rows: 24))
        #expect(!bridge.claim(cols: 80, rows: 10_001))
        #expect(bridge.claim(cols: 1, rows: 1))
        #expect(bridge.claim(cols: 10_000, rows: 10_000))
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        defer { helper.close() }
        #expect(waitUntil { link.claims.count == 2 })
        #expect(!bridge.claim(cols: 0, rows: 0))
        #expect(bridge.claim(cols: 120, rows: 40))
        #expect(link.claims == [[1, 1], [10_000, 10_000], [120, 40]])
        bridge.stop()
        #expect(!bridge.claim(cols: 80, rows: 24))
        #expect(link.claims.count == 3)
    }

    @Test func reconnectStopsTheOldLinkStartsTheNewOneAndKeepsTheHelper() throws {
        let old = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(old)
        events.attach(to: bridge)
        defer { bridge.stop() }
        bridge.claim(cols: 100, rows: 30)
        #expect(old.claims == [[100, 30]])
        old.end(.connectionLost)
        // No link is live: kept for the next one.
        bridge.claim(cols: 110, rows: 35)
        #expect(old.claims == [[100, 30]])

        let new = FakeLink()
        bridge.reconnect(with: new)
        #expect(waitUntil { old.stops == 1 })
        #expect(new.starts == 1)
        // Only what was kept; the claim the old link carried is not sent again.
        #expect(new.claims == [[110, 35]])

        // The old link is not heard from again.
        old.deliver(.data([0x01]))
        old.deliver(.resize(cols: 1, rows: 1, own: false))
        old.end(.sessionEnded)
        new.deliver(.snapshot([0x1B, 0x63, 0x41]))
        #expect(helper.read(3) == [0x1B, 0x63, 0x41])
        #expect(events.ends == [.connectionLost])
        #expect(events.resizes.isEmpty)

        helper.write([0x62])
        #expect(waitUntil { new.sends == [[0x62]] })
        #expect(old.sends.isEmpty)
    }

    /// `reconnect` is called from the main actor, and the old link's `stop()` waits
    /// for a callback that may be blocked on a surface that is not reading.
    @Test func reconnectReturnsAtOnceWhenTheOldLinksStopBlocks() throws {
        let old = FakeLink()
        let (bridge, helper) = try connected(old)
        defer { helper.close() }
        defer { bridge.stop() }
        let gate = DispatchSemaphore(value: 0)
        old.blockStop(on: gate)
        let new = FakeLink()
        let reconnecting = BackgroundCall { bridge.reconnect(with: new) }
        #expect(reconnecting.wait(1))
        #expect(new.starts == 1)
        #expect(waitUntil { old.stops == 1 })
        gate.signal()
    }

    /// The race the write lock closes: an old link's message that is waiting to write
    /// when `reconnect` swaps the link is never written, so nothing of the old link
    /// follows the new link's snapshot.
    @Test func nothingOfTheOldLinkReachesTheHelperAfterAReconnect() throws {
        let old = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: old,
                                        countsWaitingWrites: true)
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        #expect(waitUntil { old.starts == 1 })
        defer { helper.close() }
        defer { bridge.stop() }
        // A write in progress, blocked: far more than the socket holds.
        let big = [UInt8](repeating: 0x6F, count: 4 << 20)
        let inProgress = BackgroundCall { old.deliver(.data(big)) }
        #expect(!inProgress.wait(0.3))
        // A second message of the old link, queued for the helper behind it.
        let waiting = BackgroundCall { old.deliver(.data([0x58, 0x58])) }
        #expect(waitUntil { bridge.waitingHelperWrites == 1 })

        let new = FakeLink()
        let reconnecting = BackgroundCall { bridge.reconnect(with: new) }
        #expect(reconnecting.wait(1))
        let snapshot: [UInt8] = [0x1B, 0x63, 0x4E]
        let newWrite = BackgroundCall { new.deliver(.snapshot(snapshot)) }

        let received = helper.read(big.count + snapshot.count, within: 20)
        #expect(inProgress.wait())
        #expect(waiting.wait())
        #expect(newWrite.wait())
        // The write in progress completes, then the new snapshot, and nothing else.
        #expect(received.count == big.count + snapshot.count)
        #expect(Array(received.suffix(snapshot.count)) == snapshot)
        #expect(!received.contains(0x58))
        #expect(staysSilent(helper.fd, for: 0.2))
    }

    /// A helper that goes away while the bridge is writing to it does not take the
    /// app with it: the write fails (no SIGPIPE), the message's callback returns, and
    /// the helper going away is reported.
    @Test func aHelperThatGoesAwayDuringAWriteDoesNotKillTheProcess() throws {
        let link = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(link)
        events.attach(to: bridge)
        defer { bridge.stop() }
        // Far more than the socket holds, so the write is in progress, blocked.
        let big = [UInt8](repeating: 0x61, count: 4 << 20)
        let writing = BackgroundCall { link.deliver(.data(big)) }
        #expect(!writing.wait(0.3))
        helper.close()
        #expect(writing.wait())
        #expect(waitUntil { events.gone == 1 })
        // And a write after it is gone is dropped, not attempted on a closed socket.
        link.deliver(.data([0x41]))
    }

    @Test func aHelperThatGoesAwayIsReportedOnce() throws {
        let link = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(link)
        events.attach(to: bridge)
        defer { bridge.stop() }
        helper.close()
        #expect(waitUntil { events.gone == 1 })
        #expect(link.stops == 1)
        Thread.sleep(forTimeInterval: 0.1)   // room for a second report to show
        #expect(events.gone == 1)
    }

    @Test func stopIsNotReportedAsTheHelperGoingAway() throws {
        let link = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(link)
        events.attach(to: bridge)
        bridge.stop()
        #expect(helper.seesEnd())
        Thread.sleep(forTimeInterval: 0.1)   // room for a report to show
        #expect(events.gone == 0)
        #expect(link.stops == 1)
    }

    @Test func theHelperSocketIsPrivateCloseOnExecQuietAndForOneClient() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        defer { bridge.stop() }
        let path = bridge.helperSocketPath
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)

        // The listener, while there is one: before the helper connects.
        let listener = bridge.listeningDescriptor
        #expect(listener >= 0)
        #expect(fcntl(listener, F_GETFD) & FD_CLOEXEC != 0)
        #expect(option(listener, SO_NOSIGPIPE) != 0)

        let helper = try UnixTestSocket(connectingTo: path)
        #expect(waitUntil { link.starts == 1 })
        #expect(waitUntil { bridge.helperDescriptor != nil })
        let accepted = try #require(bridge.helperDescriptor)
        #expect(fcntl(accepted, F_GETFD) & FD_CLOEXEC != 0)
        #expect(option(accepted, SO_NOSIGPIPE) != 0)

        // One helper is all a bridge accepts, so the listener is closed once it has:
        // a second client is refused (or, if it slipped into the backlog before the
        // close, ended), and the first keeps working. The file stays until `stop()`.
        #expect(bridge.listeningDescriptor == -1)
        if let second = try? UnixTestSocket(connectingTo: path) {
            #expect(second.seesEnd())
        }
        #expect(lstat(path, &info) == 0)
        link.deliver(.data([0x41]))
        #expect(helper.read(1) == [0x41])
        #expect(link.starts == 1)

        bridge.stop()
        #expect(lstat(path, &info) != 0)
        #expect(helper.seesEnd())
        bridge.stop()   // idempotent
    }

    @Test func stopDoesNotHangOnAHelperThatIsNotReading() throws {
        let link = FakeLink()
        let (bridge, helper) = try connected(link)
        defer { helper.close() }
        let chunk = [UInt8](repeating: 0x61, count: 64 << 10)
        let delivery = BackgroundCall {
            for _ in 0..<64 { link.deliver(.data(chunk)) }
        }
        #expect(!delivery.wait(0.5))
        let stopping = BackgroundCall { bridge.stop() }
        #expect(stopping.wait())
        #expect(delivery.wait())
        #expect(link.stops == 1)
        var info = stat()
        #expect(lstat(bridge.helperSocketPath, &info) != 0)
    }

    @Test func stopBeforeAHelperConnectsUnlinksThePath() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        bridge.stop()
        var info = stat()
        #expect(lstat(bridge.helperSocketPath, &info) != 0)
        #expect(link.starts == 0)
        #expect(throws: (any Error).self) { try UnixTestSocket(connectingTo: bridge.helperSocketPath) }
    }

    // MARK: End to end

    /// The real server, the real link, the real bridge and the bundled `wietty-pty`:
    /// what the terminal writes reaches the helper's standard output unchanged, and
    /// what is typed on its standard input reaches the terminal.
    @Test func theStreamReachesTheRealHelperAndItsInputComesBack() throws {
        let streamer = LocalFakeStreamer()
        let snapshot: [UInt8] = [0x1B, 0x63, 0x41, 0xFF]
        streamer.onAttach = [.resize(cols: 80, rows: 24, own: false), .snapshot(snapshot)]
        let server = try LocalStreamServer(path: shortSocketPath("tbs"), streamer: streamer)
        server.start()
        defer { server.stop() }

        let link = LocalSocketLink(path: server.path, session: "gt:e2e")
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tbh"), link: link)
        let events = BridgeEvents()
        events.attach(to: bridge)
        defer { bridge.stop() }

        let process = Process()
        process.executableURL = try bundledHelperURL()
        process.arguments = [bridge.helperSocketPath]
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let output = fromHelper.fileHandleForReading.fileDescriptor
        #expect(readExactly(output, snapshot.count) == snapshot)
        #expect(events.resizes == [[80, 24, 0]])
        let id = try #require(streamer.attaches.first { $0.session == "gt:e2e" }?.id)
        let data: [UInt8] = [0xC3, 0x28, 0x0D, 0x0A, 0x00, 0xE2, 0x82]
        streamer.deliver(.data(data), to: id)
        #expect(readExactly(output, data.count) == data)

        let typed: [UInt8] = [0x6C, 0x73, 0x0D, 0xFF, 0x03]
        toHelper.fileHandleForWriting.write(Data(typed))
        #expect(waitUntil { Array(streamer.inputs.map(\.bytes).joined()) == typed })
        #expect(streamer.inputs.allSatisfy { $0.session == "gt:e2e" })

        // The surface goes away: the helper exits, and the bridge lets go of the stream.
        process.terminate()
        process.waitUntilExit()
        #expect(waitUntil { streamer.detaches == [id] })
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
