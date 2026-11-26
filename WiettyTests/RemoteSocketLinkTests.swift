import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// What a link did, in one ordered log, and an optional gate its `onMessage` waits on.
/// The test writes its own steps into the same log, so an ordering can be asserted
/// instead of an absence waited for.
private final class LinkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messageList: [StreamMessage] = []
    private var endList: [TerminalEndReason] = []
    private var eventList: [String] = []
    private var gate: DispatchSemaphore?
    private var insideCount = 0
    private var mostInside = 0
    private var onMainThread = false

    var messages: [StreamMessage] { lock.withLock { messageList } }
    var ends: [TerminalEndReason] { lock.withLock { endList } }
    var events: [String] { lock.withLock { eventList } }
    /// Callbacks that have started and not returned.
    var inside: Int { lock.withLock { insideCount } }
    /// The most callbacks that ever ran at once.
    var mostAtOnce: Int { lock.withLock { mostInside } }
    var sawMainThread: Bool { lock.withLock { onMainThread } }

    /// From now on, every `onMessage` waits on `gate` (at most ten seconds, so a broken
    /// test ends) after logging its message.
    func block(on gate: DispatchSemaphore) { lock.withLock { self.gate = gate } }
    func unblock() { lock.withLock { gate = nil } }

    func note(_ event: String) { lock.withLock { eventList.append(event) } }

    func index(of event: String) -> Int? { events.firstIndex(of: event) }

    var snapshotIndex: Int? { messages.firstIndex { if case .snapshot = $0 { true } else { false } } }

    /// Every `data` payload, joined.
    var dataBytes: [UInt8] {
        messages.flatMap { message -> [UInt8] in
            if case let .data(bytes) = message { bytes } else { [] }
        }
    }

    func attach(to link: RemoteSocketLink, also: (@Sendable (StreamMessage) -> Void)? = nil) {
        link.onMessage = { [self] message in
            lock.lock()
            let number = messageList.count
            messageList.append(message)
            eventList.append("enter \(number)")
            insideCount += 1
            mostInside = max(mostInside, insideCount)
            if Thread.isMainThread { onMainThread = true }
            let waitOn = gate
            lock.unlock()
            _ = waitOn?.wait(timeout: .now() + 10)
            also?(message)
            lock.lock()
            insideCount -= 1
            eventList.append("exit \(number)")
            lock.unlock()
        }
        link.onEnded = { [self] reason in
            lock.withLock {
                endList.append(reason)
                eventList.append("ended")
                if Thread.isMainThread { onMainThread = true }
            }
        }
    }
}

/// The serving side, as the app has it but with no pty: a real `RemoteServer` on
/// 127.0.0.1 with a throwaway token, over a real `PaneStreamHub` whose sessions are
/// libghostty-vt models. What the server hands the pty's writer is recorded.
@MainActor
private final class LinkServer {
    let server: RemoteServer
    let hub: PaneStreamHub
    let port: Int
    let token: String
    private let suite: String
    private let state: HubState

    private init(server: RemoteServer, hub: PaneStreamHub, state: HubState, port: Int, token: String,
                 suite: String) {
        self.server = server
        self.hub = hub
        self.state = state
        self.port = port
        self.token = token
        self.suite = suite
    }

    static func start() async throws -> LinkServer {
        let suite = "test.remote-link.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let token = RemoteAccessToken(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let state = HubState()
        let hub = PaneStreamHub(startTimer: true)
        state.wire(hub)
        let server = RemoteServer(store: store, streamer: hub, token: token, host: "127.0.0.1", port: 0)
        await server.start()
        let deadline = Date().addingTimeInterval(10)
        while server.boundPort == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let port = try #require(server.boundPort)
        return LinkServer(server: server, hub: hub, state: state, port: port, token: token.value, suite: suite)
    }

    var inputs: [[UInt8]] { state.inputs }
    var claims: [TerminalSize] { state.claims }

    func connection(token: String? = nil) -> RemoteConnection {
        RemoteConnection(id: UUID(), name: "link-test", host: "127.0.0.1", port: port, token: token ?? self.token)
    }

    func add(_ session: String, cols: Int = 80, rows: Int = 24) throws {
        try state.add(session, cols: cols, rows: rows)
    }

    /// Through the hub, as the pty's reader would.
    func write(_ session: String, _ text: String) { hub.write(session: session, bytes: Array(text.utf8)) }

    /// The session's terminal ends: its viewers are sent `ended`.
    func end(_ session: String) {
        hub.endViewers(ofSession: session)
        state.remove(session)
    }

    /// Idempotent.
    func stop() {
        server.stop()
        hub.stop()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

/// The hub's callbacks: the models, and what reached the pty's writer and the resize.
private final class HubState: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: GhosttyVtScreenModel] = [:]
    private var inputList: [[UInt8]] = []
    private var claimList: [TerminalSize] = []

    var inputs: [[UInt8]] { lock.withLock { inputList } }
    var claims: [TerminalSize] { lock.withLock { claimList } }

    func model(_ session: String) -> GhosttyVtScreenModel? { lock.withLock { models[session] } }

    func add(_ session: String, cols: Int, rows: Int) throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: cols, rows: rows),
                                             scrollbackLines: 1_000, graphemeClustering: true)
        lock.withLock { models[session] = model }
    }

    func remove(_ session: String) { _ = lock.withLock { models.removeValue(forKey: session) } }

    func wire(_ hub: PaneStreamHub) {
        hub.onIngest = { [weak self] session, bytes in self?.model(session)?.write(bytes) }
        hub.onSnapshot = { [weak self] session in
            guard let frame = self?.model(session)?.snapshotFrame() else { return nil }
            return frame.bytes.isEmpty ? nil : frame
        }
        hub.onRepaint = { [weak self] session in self?.model(session)?.repaintFrame() }
        hub.onAlternateScreen = { [weak self] session in self?.model(session)?.isAlternateScreen ?? false }
        hub.onClaim = { [weak self] session, size in
            guard let self else { return }
            lock.withLock { claimList.append(size) }
            model(session)?.resize(to: size)
        }
        hub.onInput = { [weak self] _, bytes in
            guard let self else { return }
            lock.withLock { inputList.append(bytes) }
        }
        hub.onSessionCensus = { [weak self] in
            guard let self else { return .unknown }
            return .sessions(lock.withLock { Set(models.keys) })
        }
    }
}

/// `RemoteSocketLink` against a real `RemoteServer` on 127.0.0.1: the link a pane uses
/// for a terminal on another Mac.
@MainActor
@Suite(.serialized) struct RemoteSocketLinkTests {
    private func started(_ server: LinkServer, _ log: LinkLog, session: String = "s1",
                         token: String? = nil,
                         also: (@Sendable (StreamMessage) -> Void)? = nil) -> RemoteSocketLink {
        let link = RemoteSocketLink(connection: server.connection(token: token), session: session)
        log.attach(to: link, also: also)
        link.start()
        return link
    }

    @Test func itDeliversTheSnapshotThenLiveDataInOrderOnItsOwnQueue() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        server.write("s1", "BEFORE-ATTACH\r\n")
        let log = LinkLog()
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        let live = (1...20).map { "LIVE-\($0)\r\n" }
        for line in live { server.write("s1", line) }
        let expected = Array(live.joined().utf8)
        #expect(waitUntil(within: 10) { log.dataBytes.count >= expected.count })
        link.waitForCallbacks()

        let messages = log.messages
        let snapshot = try #require(log.snapshotIndex)
        // What was written before the attach is in the snapshot, not in the stream.
        guard case let .snapshot(frame) = messages[snapshot] else { Issue.record("no snapshot"); return }
        #expect(String(decoding: frame, as: UTF8.self).contains("BEFORE-ATTACH"))
        let firstData = messages.firstIndex { if case .data = $0 { true } else { false } }
        #expect(firstData.map { $0 > snapshot } == true)
        #expect(log.dataBytes == expected)
        // The hello is consumed, never delivered.
        #expect(!messages.contains { if case .hello = $0 { true } else { false } })
        #expect(log.mostAtOnce == 1)
        #expect(!log.sawMainThread)
        #expect(log.ends.isEmpty)
    }

    @Test func inputReachesThePtyWriterInOrder() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        let big = (0..<150_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let expected: [UInt8] = [0x61, 0x62] + big + [0xC3, 0x28]
        link.send([0x61, 0x62])
        link.send(big)
        link.send([0xC3, 0x28])
        #expect(waitUntil(within: 10) { server.inputs.joined().count >= expected.count })
        #expect(Array(server.inputs.joined()) == expected)
    }

    @Test func aClaimIsAnsweredWithOwnTrue() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        link.claim(cols: 100, rows: 30)
        #expect(waitUntil(within: 10) { log.messages.contains(.resize(cols: 100, rows: 30, own: true)) })
        #expect(server.claims == [TerminalSize(cols: 100, rows: 30)])
    }

    /// A claim and input made before `start()` never reach the server. Shown by order:
    /// the server answers one viewer's claims in the order they were made, so a claim
    /// made before `start()` and kept would have been answered before the first one
    /// made after it.
    @Test func sendAndClaimBeforeStartAreDropped() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = RemoteSocketLink(connection: server.connection(), session: "s1")
        log.attach(to: link)
        defer { link.stop() }
        link.send([0x01])
        link.claim(cols: 100, rows: 30)
        link.start()
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        link.claim(cols: 90, rows: 25)
        link.send([0x02])
        #expect(waitUntil(within: 10) {
            log.messages.contains { if case .resize(_, _, true) = $0 { true } else { false } }
                && !server.inputs.isEmpty
        })
        let answers = log.messages.filter { if case .resize(_, _, true) = $0 { true } else { false } }
        #expect(answers == [.resize(cols: 90, rows: 25, own: true)])
        #expect(server.claims == [TerminalSize(cols: 90, rows: 25)])
        #expect(server.inputs == [[0x02]])
    }

    @Test func endedEndsItAsSessionEndedOnceAfterTheDataBeforeIt() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        server.write("s1", "LAST-WORDS")
        server.end("s1")
        #expect(waitUntil(within: 10) { !log.ends.isEmpty })
        link.waitForCallbacks()
        #expect(log.ends == [.sessionEnded])
        #expect(log.events.last == "ended")
        #expect(log.dataBytes == Array("LAST-WORDS".utf8))
        // After the end, input and claims are dropped, and a second end, should the
        // package hand one over, fires nothing.
        link.send([0x01])
        link.claim(cols: 100, rows: 30)
        #expect(throughTheSeam { link.end(.connectionLost) })
        link.waitForCallbacks()
        #expect(server.inputs.isEmpty)
        #expect(server.claims.isEmpty)
        #expect(log.ends == [.sessionEnded])
    }

    /// A link is used once: ended, it does not start again.
    @Test func anEndedLinkDoesNotStartAgain() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        server.end("s1")
        #expect(waitUntil(within: 10) { !log.ends.isEmpty })
        try server.add("s1")
        link.start()
        #expect(!link.isLive)
        // Through the seam, a message handed to the ended link is not delivered either.
        let delivered = log.messages.count
        #expect(throughTheSeam { link.deliver(.data([0x01])) })
        link.waitForCallbacks()
        #expect(log.messages.count == delivered)
        #expect(log.ends == [.sessionEnded])
    }

    /// The server refuses the upgrade with an HTTP status, before any WebSocket frame,
    /// so there is no `error` message to carry a refusal: URLSession fails the receive,
    /// and the package ends the stream as `.connectionLost`, which the link passes on.
    @Test func aWrongTokenEndsItAsConnectionLost() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let wrong = String(repeating: "0", count: 32)
        let link = started(server, log, token: wrong)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { !log.ends.isEmpty })
        link.waitForCallbacks()
        #expect(log.messages.isEmpty)
        #expect(log.ends == [.connectionLost])
    }

    /// A session the server has no terminal for is answered with `ended` after the
    /// hello, so the link ends as `.sessionEnded`, not as a lost connection.
    @Test func anUnknownSessionEndsItAsSessionEnded() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log, session: "nobody")
        defer { link.stop() }
        #expect(waitUntil(within: 10) { !log.ends.isEmpty })
        link.waitForCallbacks()
        #expect(log.ends == [.sessionEnded])
    }

    /// A port that was listening and is closed: nothing answers the connect.
    @Test func aClosedListenerEndsItAsConnectionLost() async throws {
        let port = try closedPort()
        let link = RemoteSocketLink(
            connection: RemoteConnection(id: UUID(), name: "link-test", host: "127.0.0.1", port: port,
                                         token: String(repeating: "a", count: 32)),
            session: "s1")
        let log = LinkLog()
        log.attach(to: link)
        link.start()
        defer { link.stop() }
        #expect(waitUntil(within: 10) { !log.ends.isEmpty })
        link.waitForCallbacks()
        #expect(log.ends == [.connectionLost])
        #expect(log.messages.isEmpty)
    }

    /// While `onMessage` has not returned, the package hands the link nothing more: the
    /// next frame stays unread. The positive sign that the next messages were sent while
    /// the first callback was blocked is a second, unblocked link on the same session
    /// receiving the live data written meanwhile (the attach's snapshot was sent before
    /// that). A link that handed each message to another queue and returned would let
    /// the package read on, and `arrivals` would pass one. What this cannot prove is
    /// that the frames had reached this client's socket at the moment of the check, as
    /// opposed to the sibling's: the bounded wait below gives them that room.
    @Test func aBlockingOnMessageLeavesTheNextFrameUnread() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let siblingLog = LinkLog()
        let sibling = started(server, siblingLog)
        defer { sibling.stop() }
        #expect(waitUntil(within: 10) { siblingLog.snapshotIndex != nil })
        let log = LinkLog()
        let gate = DispatchSemaphore(value: 0)
        log.block(on: gate)
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.inside == 1 })
        // Live data behind the attach's messages, all held back by the first callback.
        server.write("s1", "HELD-BACK")
        #expect(waitUntil(within: 10) { siblingLog.dataBytes == Array("HELD-BACK".utf8) })
        // Room for a link that does not hold the package back to be handed the next.
        #expect(!waitUntil(within: 0.5) { link.arrivals > 1 })
        #expect(link.arrivals == 1)
        log.note("release")
        log.unblock()
        gate.signal()
        #expect(waitUntil(within: 10) { log.dataBytes == Array("HELD-BACK".utf8) })
        link.waitForCallbacks()
        let events = log.events
        let release = try #require(events.firstIndex(of: "release"))
        #expect(events.firstIndex(of: "enter 1").map { $0 > release } == true)
        #expect(events.firstIndex(of: "exit 0").map { $0 > release } == true)
        // Strictly one at a time: enter n, exit n, enter n + 1, ...
        let callbacks = events.filter { $0 != "release" }
        let alternating = callbacks.enumerated().allSatisfy { offset, event in
            event == (offset.isMultiple(of: 2) ? "enter \(offset / 2)" : "exit \(offset / 2)")
        }
        #expect(alternating)
        #expect(log.mostAtOnce == 1)
    }

    /// From another thread, `stop()` returns only after a callback in progress has
    /// returned, and nothing of the link runs after it: the attach's snapshot, already
    /// on its way, is never delivered.
    @Test func stopFromAnotherThreadWaitsForABlockedCallbackAndNothingFollows() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let gate = DispatchSemaphore(value: 0)
        log.block(on: gate)
        let link = started(server, log)
        #expect(waitUntil(within: 10) { log.inside == 1 })
        server.write("s1", "AFTER-STOP")
        let stopping = BackgroundCall {
            log.note("stop called")
            link.stop()
            log.note("stop returned")
        }
        #expect(waitUntil { log.index(of: "stop called") != nil })
        // Room for a stop that does not wait to return; the order below is the proof.
        _ = waitUntil(within: 0.3) { stopping.hasFinished }
        log.unblock()
        gate.signal()
        #expect(stopping.wait(10))
        link.waitForCallbacks()
        // The package drops what it still had for a stopped stream; through the seam,
        // a message and an end that reach the link after the stop anyway are not passed on.
        #expect(throughTheSeam { link.deliver(.data(Array("LATE".utf8))); link.end(.connectionLost) })
        link.waitForCallbacks()
        let events = log.events
        let exited = try #require(events.firstIndex(of: "exit 0"))
        let returned = try #require(events.firstIndex(of: "stop returned"))
        #expect(exited < returned)
        #expect(events.last == "stop returned")
        #expect(log.messages.count == 1)
        #expect(log.ends.isEmpty)
    }

    /// From inside its own callback, `stop()` cannot wait for that callback: it returns
    /// at once, and nothing comes after it.
    @Test func stopFromInsideACallbackReturnsAtOnceAndNothingFollows() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = RemoteSocketLink(connection: server.connection(), session: "s1")
        log.attach(to: link, also: { [link, log] _ in
            log.note("stopping")
            link.stop()
            log.note("stopped")
        })
        link.start()
        // Bounded: a `stop()` that waits for its own callback deadlocks the link's queue,
        // and then the queue must not be waited on.
        guard waitUntil(within: 10, { log.index(of: "stopped") != nil }) else {
            Issue.record("stop() from inside a callback did not return")
            return
        }
        server.write("s1", "AFTER-STOP")
        server.end("s1")
        link.waitForCallbacks()
        #expect(throughTheSeam { link.deliver(.data(Array("LATE".utf8))); link.end(.sessionEnded) })
        link.waitForCallbacks()
        #expect(log.events == ["enter 0", "stopping", "stopped", "exit 0"])
        #expect(log.messages.count == 1)
        #expect(log.ends.isEmpty)
    }

    /// Stopped, the link fires no `onEnded`: not for the session ending, not for the
    /// server going away, and not for an end that reaches it after the stop anyway (the
    /// package's own drop is bypassed through the seam, so the link's guard is tested).
    @Test func noOnEndedAfterStop() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        let stopping = BackgroundCall { link.stop() }
        #expect(stopping.wait(10))
        let delivered = log.messages.count
        server.end("s1")
        server.stop()
        #expect(throughTheSeam { link.end(.sessionEnded); link.end(.connectionLost) })
        link.waitForCallbacks()
        #expect(log.ends.isEmpty)
        #expect(log.messages.count == delivered)
        link.stop()   // idempotent
    }

    /// Live, the link ends once, however many ends the package hands it.
    @Test func aLiveLinkEndsOnce() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        defer { link.stop() }
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        let delivered = log.messages.count
        #expect(throughTheSeam {
            link.end(.connectionLost)
            link.end(.sessionEnded)
            link.deliver(.data([0x01]))
        })
        link.waitForCallbacks()
        #expect(log.ends == [.connectionLost])
        #expect(log.messages.count == delivered)
        #expect(!link.isLive)
    }

    /// A link is used once: stopped, it does not start again.
    @Test func aStoppedLinkDoesNotStartAgain() async throws {
        let server = try await LinkServer.start()
        defer { server.stop() }
        try server.add("s1")
        let log = LinkLog()
        let link = started(server, log)
        #expect(waitUntil(within: 10) { log.snapshotIndex != nil })
        link.stop()
        link.start()
        #expect(!link.isLive)
    }
}

/// Calls the link's entry points from the package (`deliver`, `end`) on a thread of its
/// own, as the package would from the link's queue, and says whether they returned
/// within five seconds. Bounded because a link whose guard is broken may run a callback
/// that calls `stop()`, which then waits for the callback it is in.
private func throughTheSeam(_ body: @escaping @Sendable () -> Void) -> Bool {
    BackgroundCall(body).wait(5)
}

/// A loopback port that was bound and listening, and is closed now.
private func closedPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try #require(named == 0)
    return Int(UInt16(bigEndian: addr.sin_port))
}
