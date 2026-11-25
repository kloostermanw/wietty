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
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
    func send(_ bytes: [UInt8]) { lock.lock(); sent.append(bytes); lock.unlock() }
    func claim(cols: Int, rows: Int) { lock.lock(); claimed.append([cols, rows]); lock.unlock() }

    func deliver(_ message: StreamMessage) { onMessage?(message) }
    func end(_ reason: TerminalEndReason) { onEnded?(reason) }
}

private final class BridgeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var resizeList: [[Int]] = []
    private var endList: [TerminalEndReason] = []
    var resizes: [[Int]] { lock.lock(); defer { lock.unlock() }; return resizeList }
    var ends: [TerminalEndReason] { lock.lock(); defer { lock.unlock() }; return endList }

    func attach(to bridge: TerminalBridge) {
        bridge.onResize = { [self] cols, rows, own in
            lock.lock(); resizeList.append([cols, rows, own ? 1 : 0]); lock.unlock()
        }
        bridge.onEnded = { [self] reason in
            lock.lock(); endList.append(reason); lock.unlock()
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

    @Test func aClaimBeforeTheLinkStartsIsSentWhenItStarts() throws {
        let link = FakeLink()
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("tb"), link: link)
        defer { bridge.stop() }
        bridge.claim(cols: 90, rows: 20)
        bridge.claim(cols: 100, rows: 30)
        #expect(link.claims.isEmpty)
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        defer { helper.close() }
        #expect(waitUntil { link.claims == [[100, 30]] })
        bridge.claim(cols: 120, rows: 40)
        #expect(link.claims == [[100, 30], [120, 40]])
    }

    @Test func reconnectStopsTheOldLinkStartsTheNewOneAndKeepsTheHelper() throws {
        let old = FakeLink()
        let events = BridgeEvents()
        let (bridge, helper) = try connected(old)
        events.attach(to: bridge)
        defer { bridge.stop() }
        bridge.claim(cols: 100, rows: 30)
        old.end(.connectionLost)

        let new = FakeLink()
        bridge.reconnect(with: new)
        #expect(old.stops == 1)
        #expect(new.starts == 1)
        // The last claim goes to the new stream too.
        #expect(new.claims == [[100, 30]])

        // The old link is not heard from again.
        old.deliver(.data([0x01]))
        old.end(.sessionEnded)
        new.deliver(.snapshot([0x1B, 0x63, 0x41]))
        #expect(helper.read(3) == [0x1B, 0x63, 0x41])
        #expect(events.ends == [.connectionLost])

        helper.write([0x62])
        #expect(waitUntil { new.sends == [[0x62]] })
        #expect(old.sends.isEmpty)
    }

    @Test func theHelperSocketIsPrivateCloseOnExecQuietAndForOneClient() throws {
        let link = FakeLink()
        let (bridge, helper) = try connected(link)
        let path = bridge.helperSocketPath
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)

        let listener = bridge.listeningDescriptor
        #expect(listener >= 0)
        #expect(fcntl(listener, F_GETFD) & FD_CLOEXEC != 0)
        #expect(option(listener, SO_NOSIGPIPE) != 0)
        #expect(waitUntil { bridge.helperDescriptor != nil })
        let accepted = try #require(bridge.helperDescriptor)
        #expect(fcntl(accepted, F_GETFD) & FD_CLOEXEC != 0)
        #expect(option(accepted, SO_NOSIGPIPE) != 0)

        // A second client is closed, and the first keeps working.
        let second = try UnixTestSocket(connectingTo: path)
        #expect(second.seesEnd())
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
