import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// A streamer the test drives: it records what the route asks of it and hands
/// the test each viewer's sink, so the route is tested with no terminal behind it.
private final class RouteStreamer: ScreenStreaming, @unchecked Sendable {
    struct Attach: Equatable {
        let session: String
        let resize: ResizeMode
        let id: UUID
    }
    struct Claim: Equatable {
        let id: UUID
        let cols: Int
        let rows: Int
    }

    private let lock = NSLock()
    private var sinks: [UUID: @Sendable (StreamMessage) -> Void] = [:]
    private var attachList: [Attach] = []
    private var sentList: [[UInt8]] = []
    private var detachedList: [UUID] = []
    private var resyncList: [UUID] = []
    /// What the attach delivers before it returns, as the hub delivers the grid and
    /// the snapshot.
    var onAttach: [StreamMessage] = [.resize(cols: 80, rows: 24, own: false), .snapshot([0x41])]
    /// Whether a resync is answered with "no snapshot", or left for the test.
    var answerResyncUnavailable = true

    func attach(session: String, resize: ResizeMode,
                onMessage: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        sinks[id] = onMessage
        attachList.append(Attach(session: session, resize: resize, id: id))
        let initial = onAttach
        lock.unlock()
        for message in initial { onMessage(message) }
        return id
    }
    private var localAttachList: [Attach] = []
    /// Every local attach made, in order. The route never makes one.
    var localAttaches: [Attach] { lock.lock(); defer { lock.unlock() }; return localAttachList }
    func attachLocal(session: String, resize: ResizeMode,
                     write: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); localAttachList.append(Attach(session: session, resize: resize, id: id)); lock.unlock()
        return id
    }
    func detach(connectionId: UUID) {
        lock.lock(); detachedList.append(connectionId); sinks[connectionId] = nil; lock.unlock()
    }
    func send(session: String, bytes: [UInt8]) {
        lock.lock(); sentList.append(bytes); lock.unlock()
    }
    func resync(connectionId: UUID, onUnavailable: @escaping @Sendable () -> Void) {
        lock.lock(); resyncList.append(connectionId); let answer = answerResyncUnavailable; lock.unlock()
        guard answer else { return }
        // Later and elsewhere, as the hub answers.
        DispatchQueue.global().async { [self] in
            onUnavailable()
            lock.lock(); answeredCount += 1; lock.unlock()
        }
    }
    private var answeredCount = 0
    /// Resyncs answered with "no snapshot" so far, counted once the answer returned.
    var answered: Int { lock.lock(); defer { lock.unlock() }; return answeredCount }
    func stop() {}
    private var claimList: [Claim] = []
    /// Recorded, and answered as the hub answers a claim: one `resize` with `own`
    /// true, to the claimant alone, later and elsewhere.
    func claim(connectionId: UUID, cols: Int, rows: Int) {
        lock.lock()
        claimList.append(Claim(id: connectionId, cols: cols, rows: rows))
        let sink = sinks[connectionId]
        lock.unlock()
        DispatchQueue.global().async { sink?(.resize(cols: cols, rows: rows, own: true)) }
    }
    /// Every claim the route made, in order.
    var claims: [Claim] { lock.lock(); defer { lock.unlock() }; return claimList }

    var attaches: [Attach] { lock.lock(); defer { lock.unlock() }; return attachList }
    var sent: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return sentList }
    var detached: [UUID] { lock.lock(); defer { lock.unlock() }; return detachedList }
    var resyncs: [UUID] { lock.lock(); defer { lock.unlock() }; return resyncList }

    /// Hands a message to the one attached viewer.
    func deliver(_ message: StreamMessage) {
        lock.lock(); let sink = sinks.values.first; lock.unlock()
        sink?(message)
    }
}

/// A real WebSocket client on a real socket.
private final class Client: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var timedOutFlag = false
    /// A receive gave up waiting, so a failed receive says nothing about the server.
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutFlag }
    private func markTimedOut() { lock.withLock { timedOutFlag = true } }

    init(url: URL) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = StreamProtocol.maxMessageSize
        task.resume()
    }

    /// The next frame. A frame that never comes fails the test after ten seconds
    /// rather than hanging the suite: the socket is cancelled, which fails the
    /// receive.
    func receive() async throws -> URLSessionWebSocketTask.Message {
        let task = self.task
        let watchdog = Task { [self] in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            markTimedOut()
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        return try await task.receive()
    }

    /// The next frame as a `StreamMessage`, nil for a frame the codec cannot read.
    func message() async throws -> StreamMessage? {
        switch try await receive() {
        case let .string(text): StreamCodec.message(from: .text(text))
        case let .data(data): StreamCodec.message(from: .binary(Array(data)))
        @unknown default: nil
        }
    }

    func text() async throws -> String? {
        if case let .string(text) = try await receive() { return text }
        return nil
    }

    func send(_ message: StreamMessage) async throws {
        switch StreamCodec.webSocketFrame(for: message) {
        case let .text(text): try await task.send(.string(text))
        case let .binary(bytes): try await task.send(.data(Data(bytes)))
        }
    }

    /// Whether the server has closed the socket: the next receive fails.
    func isClosedByServer() async -> Bool {
        do { _ = try await receive(); return false } catch { return !timedOut }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

/// `WS /attach` against the real route: a real `RemoteServer` on a loopback port
/// chosen by the system, a real WebSocket client, and `RouteStreamer` behind it.
@Suite @MainActor struct RemoteAttachRouteTests {
    private static let oldClientText =
        "\r\n\u{1B}[31mThis app is too old for this Mac. Update Wietty on this device.\u{1B}[0m\r\n"

    private struct Running {
        let server: RemoteServer
        let streamer: RouteStreamer
        let token: String
        let port: Int
        let suite: String

        func url(_ query: String, token: String? = nil) -> URL {
            URL(string: "ws://127.0.0.1:\(port)/attach?token=\(token ?? self.token)\(query)")!
        }

        @MainActor func stop() {
            server.stop()
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private func start(_ streamer: RouteStreamer = RouteStreamer()) async throws -> Running {
        let suite = "test.remote.attach.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let token = RemoteAccessToken(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let server = RemoteServer(store: store, streamer: streamer, token: token,
                                  host: "127.0.0.1", port: 0)
        await server.start()
        let deadline = Date().addingTimeInterval(10)
        while server.boundPort == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let port = try #require(server.boundPort)
        return Running(server: server, streamer: streamer, token: token.value, port: port, suite: suite)
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    private func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Versions

    /// A client with no `protocol` parameter is an old one. It is sent exactly the
    /// two version 1 messages its decoder reads, `type` and `vt`, telling the user
    /// to update, and the server closes. Nothing is attached.
    @Test func anOldClientIsToldToUpdateAndClosed() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1"))
        defer { client.close() }

        let first = try #require(jsonObject(try await client.text()))
        #expect(Set(first.keys) == ["type", "vt"])
        #expect(first["type"] as? String == "data")
        #expect(first["vt"] as? String == Self.oldClientText)
        let second = try #require(jsonObject(try await client.text()))
        #expect(Set(second.keys) == ["type"])
        #expect(second["type"] as? String == "ended")
        #expect(await client.isClosedByServer())
        #expect(running.streamer.attaches.isEmpty)
    }

    /// The old client does not ask for its next frame at once: it hops to the main
    /// actor between two receives. The server's close must not cost it the `ended`
    /// that was sent before the close, or it reports a lost connection instead.
    @Test func anOldClientThatReadsSlowlyStillGetsBothFrames() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1"))
        defer { client.close() }

        // What the terminal view sends on its own while the notice is on its way.
        for _ in 0..<20 {
            client.task.send(.string(#"{"data":"x"}"#)) { _ in }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let first = try #require(jsonObject(try await client.text()))
        #expect(first["type"] as? String == "data")
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = try #require(jsonObject(try await client.text()))
        #expect(second["type"] as? String == "ended")
    }

    /// The two frames themselves, byte for byte as the route builds them.
    @Test func theOldClientNoticeIsTwoVersionOneFrames() throws {
        let frames = RemoteServer.oldClientNotice
        #expect(frames.count == 2)
        let first = try #require(jsonObject(frames.first))
        #expect(Set(first.keys) == ["type", "vt"])
        #expect(first["vt"] as? String == Self.oldClientText)
        #expect(jsonObject(frames.last).map { Set($0.keys) } == ["type"])
        #expect(jsonObject(frames.last)?["type"] as? String == "ended")
    }

    /// A version the server does not speak gets one `error` with code `protocol`,
    /// then the server closes. Nothing is attached.
    @Test func anUnknownVersionIsRefused() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=3&resize=repaint"))
        defer { client.close() }

        let message = try await client.message()
        guard case let .error(code, text) = message else {
            Issue.record("expected an error, got \(String(describing: message))")
            return
        }
        #expect(code == "protocol")
        #expect(!text.isEmpty)
        #expect(await client.isClosedByServer())
        #expect(running.streamer.attaches.isEmpty)
    }

    /// Version 2: the server's `hello` first, then what the streamer delivers, in
    /// its order. The resize mode comes from the query.
    @Test func versionTwoGetsTheHelloFirstThenTheStream() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2&resize=reflow"))
        defer { client.close() }

        #expect(try await client.message() == .hello(protocolVersion: 2, session: nil, resize: nil))
        #expect(try await client.message() == .resize(cols: 80, rows: 24, own: false))
        #expect(try await client.message() == .snapshot([0x41]))
        #expect(running.streamer.attaches.map(\.session) == ["gt:1"])
        #expect(running.streamer.attaches.map(\.resize) == [.reflow])
    }

    /// The hello is exactly `{"protocol":2,"type":"hello"}` on the wire.
    @Test func theHelloCarriesOnlyTheVersion() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        let hello = try #require(jsonObject(try await client.text()))
        #expect(Set(hello.keys) == ["type", "protocol"])
        #expect(hello["protocol"] as? Int == 2)
    }

    /// `resize` missing or unknown means `repaint`.
    @Test func aMissingOrUnknownResizeModeIsRepaint() async throws {
        let running = try await start()
        defer { running.stop() }
        for query in ["&session=gt:1&protocol=2", "&session=gt:2&protocol=2&resize=sideways"] {
            let client = Client(url: running.url(query))
            #expect(try await client.message() == .hello(protocolVersion: 2, session: nil, resize: nil))
            client.close()
        }
        #expect(try await eventually { running.streamer.attaches.count == 2 })
        #expect(running.streamer.attaches.map(\.resize) == [.repaint, .repaint])
    }

    // MARK: - Outbound

    /// Frames reach the socket in the order the streamer emits them.
    @Test func framesArriveInTheOrderTheyWereDelivered() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }

        let expected = (0..<500).map { StreamMessage.data(Array("line \($0)\r\n".utf8)) }
        for message in expected { running.streamer.deliver(message) }
        var received: [StreamMessage] = []
        for _ in expected { received.append(try #require(try await client.message())) }
        #expect(received == expected)
    }

    /// A snapshot of several megabytes is one binary message that arrives whole at
    /// a real client: nothing on the server limits or splits outbound frames.
    @Test func anEightMegabyteSnapshotArrivesWhole() async throws {
        let streamer = RouteStreamer()
        let big = (0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        streamer.onAttach = [.resize(cols: 80, rows: 24, own: false), .snapshot(big)]
        let running = try await start(streamer)
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }

        _ = try await client.message()
        _ = try await client.message()
        let received = try await client.message()
        #expect(received == .snapshot(big))
    }

    /// An `ended` the streamer pushes reaches the client, then the server closes
    /// the socket and the viewer is detached.
    @Test func anEndedReachesTheClientAndTheServerCloses() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }

        running.streamer.deliver(.data([0x7A]))
        running.streamer.deliver(.ended)
        #expect(try await client.message() == .data([0x7A]))
        #expect(try await client.message() == .ended)
        #expect(await client.isClosedByServer())
        let id = try #require(running.streamer.attaches.first?.id)
        #expect(try await eventually { running.streamer.detached == [id] })
    }

    /// A data message larger than the viewer's bound overflows its queue, and the
    /// overflow asks the streamer for a resync of this very viewer. Answered with
    /// "no snapshot", the stream carries on.
    @Test func anOverflowAsksForAResyncOfThisViewer() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }

        running.streamer.deliver(.data(Array(repeating: 0x2E, count: (4 << 20) + 1)))
        let id = try #require(running.streamer.attaches.first?.id)
        #expect(try await eventually { running.streamer.resyncs == [id] })
        #expect(try await eventually { running.streamer.answered == 1 })
        running.streamer.deliver(.data([0x21]))
        #expect(try await client.message() == .data([0x21]))
    }

    // MARK: - Inbound

    /// Binary `data` goes to the streamer byte exact; a text frame that is no known
    /// message (the version 1 input shape among them) is ignored. The socket stays
    /// open through all of it.
    @Test func inputIsForwardedAndEverythingElseIgnored() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }

        try await client.send(.data([0x6C, 0x73, 0x0D, 0xFF]))
        try await client.task.send(.string("{\"data\":\"old input\"}"))
        try await client.task.send(.string("not json"))
        try await client.send(.data([0x0A]))

        #expect(try await eventually { running.streamer.sent.count == 2 })
        #expect(running.streamer.sent == [[0x6C, 0x73, 0x0D, 0xFF], [0x0A]])
        #expect(running.streamer.claims.isEmpty)
        running.streamer.deliver(.data([0x31]))
        #expect(try await client.message() == .data([0x31]))
    }

    /// An inbound `resize` is a claim: it reaches the streamer with this viewer's id
    /// and grid (whatever `own` the client set), and exactly one `resize` with `own`
    /// true comes back.
    @Test func anInboundResizeIsAClaimAnsweredWithOwn() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }
        let id = try #require(running.streamer.attaches.first?.id)

        try await client.send(.resize(cols: 100, rows: 30, own: false))
        #expect(try await client.message() == .resize(cols: 100, rows: 30, own: true))
        #expect(running.streamer.claims == [RouteStreamer.Claim(id: id, cols: 100, rows: 30)])
        // One answer, not more: the next message is whatever the stream sends next.
        running.streamer.deliver(.data([0x31]))
        #expect(try await client.message() == .data([0x31]))
    }

    /// A paste far larger than the WebSocket library's default frame limit of
    /// 16 KiB arrives whole: the inbound limit is 1 MiB, frame and message.
    @Test func aLargePasteArrivesWhole() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }

        let paste = (0..<((1 << 20) - 1)).map { UInt8(0x20 + $0 % 90) }
        try await client.send(.data(paste))
        #expect(try await eventually { running.streamer.sent.count == 1 })
        #expect(running.streamer.sent.first == paste)
    }

    /// A client that closes its socket is detached.
    @Test func aClientThatClosesIsDetached() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        for _ in 0..<3 { _ = try await client.message() }
        client.close()
        let id = try #require(running.streamer.attaches.first?.id)
        #expect(try await eventually { running.streamer.detached == [id] })
    }

    // MARK: - Token and session

    /// A wrong token is not upgraded, and nothing is attached.
    @Test func aWrongTokenIsNotUpgraded() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2", token: "wrong"))
        defer { client.close() }
        await #expect(throws: (any Error).self) { try await client.receive() }
        // Refused by the server, not given up on by the watchdog.
        #expect(!client.timedOut)
        #expect(running.streamer.attaches.isEmpty)
    }

    /// The server stopping with a viewer attached detaches that viewer.
    @Test func stoppingTheServerDetachesAnAttachedViewer() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&session=gt:1&protocol=2"))
        defer { client.close() }
        for _ in 0..<3 { _ = try await client.message() }
        let id = try #require(running.streamer.attaches.first?.id)

        running.server.stop()
        #expect(try await eventually { running.streamer.detached == [id] })
        #expect(running.server.boundPort == nil)
    }

    /// No session: one `error` with code `session`, then the server closes, so the
    /// client ends for good instead of reporting a lost connection and reconnecting.
    /// Nothing is attached. The token is still checked before the upgrade.
    @Test func aMissingSessionIsRefusedWithAnError() async throws {
        let running = try await start()
        defer { running.stop() }
        let client = Client(url: running.url("&protocol=2"))
        defer { client.close() }

        let message = try await client.message()
        guard case let .error(code, text) = message else {
            Issue.record("expected an error, got \(String(describing: message))")
            return
        }
        #expect(code == "session")
        #expect(!text.isEmpty)
        #expect(await client.isClosedByServer())
        #expect(running.streamer.attaches.isEmpty)
    }
}
