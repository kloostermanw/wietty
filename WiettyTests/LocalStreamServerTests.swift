import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// Polls `condition` until it holds or `seconds` pass, so a deadlock fails the
/// test instead of hanging the suite.
private func eventually(within seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

/// Runs `body` on a thread of its own and reports when it has returned.
private final class Background: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    var hasFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    init(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            body()
            lock.lock(); finished = true; lock.unlock()
            done.signal()
        }
        thread.start()
    }

    func wait(_ seconds: Double = 5) -> Bool {
        done.wait(timeout: .now() + seconds) == .success
    }
}

/// The hub's side of a local viewer, recorded, with `write` driven by the test.
///
/// Honours the contract `LocalStreamServer` depends on: `detach` waits for a
/// `write` in progress, and no `write` starts after it.
final class LocalFakeStreamer: ScreenStreaming, @unchecked Sendable {
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
    struct Input: Hashable {
        let session: String
        let bytes: [UInt8]
    }

    /// One viewer's `write`, with the lock `detach` takes to wait for a call.
    private final class Writer: @unchecked Sendable {
        let calling = NSLock()
        var gone = false
        let write: @Sendable (StreamMessage) -> Void
        init(_ write: @escaping @Sendable (StreamMessage) -> Void) { self.write = write }
    }

    private let lock = NSLock()
    private var writers: [UUID: Writer] = [:]
    private var attachList: [Attach] = []
    private var detachList: [UUID] = []
    private var claimList: [Claim] = []
    private var inputList: [Input] = []
    private var attachInitial: [StreamMessage] = [.resize(cols: 80, rows: 24, own: false), .snapshot([0x41])]
    private var attachEnds = false
    private var attachReturns = 0

    /// What an attach writes before it returns, as the hub writes the grid and the snapshot.
    var onAttach: [StreamMessage] {
        get { lock.lock(); defer { lock.unlock() }; return attachInitial }
        set { lock.lock(); attachInitial = newValue; lock.unlock() }
    }
    /// Whether an attach is for a session that is not live: `ended`, nothing registered.
    var endsOnAttach: Bool {
        get { lock.lock(); defer { lock.unlock() }; return attachEnds }
        set { lock.lock(); attachEnds = newValue; lock.unlock() }
    }

    var attaches: [Attach] { lock.lock(); defer { lock.unlock() }; return attachList }
    var detaches: [UUID] { lock.lock(); defer { lock.unlock() }; return detachList }
    var claims: [Claim] { lock.lock(); defer { lock.unlock() }; return claimList }
    var inputs: [Input] { lock.lock(); defer { lock.unlock() }; return inputList }
    /// Attaches that have returned to their caller.
    var attachesReturned: Int { lock.lock(); defer { lock.unlock() }; return attachReturns }

    func attach(session: String, resize: ResizeMode,
                onMessage: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        UUID()
    }

    func attachLocal(session: String, resize: ResizeMode,
                     write: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        let id = UUID()
        let writer = Writer(write)
        lock.lock()
        attachList.append(Attach(session: session, resize: resize, id: id))
        let ends = attachEnds
        let initial = attachInitial
        if !ends { writers[id] = writer }
        lock.unlock()
        if ends {
            write(.ended)
        } else {
            for message in initial { _ = deliver(message, through: writer) }
        }
        lock.lock(); attachReturns += 1; lock.unlock()
        return id
    }

    /// Calls the viewer's `write` as the hub would. False when it is detached.
    @discardableResult
    func deliver(_ message: StreamMessage, to id: UUID) -> Bool {
        lock.lock()
        let writer = writers[id]
        lock.unlock()
        guard let writer else { return false }
        return deliver(message, through: writer)
    }

    private func deliver(_ message: StreamMessage, through writer: Writer) -> Bool {
        writer.calling.lock()
        defer { writer.calling.unlock() }
        guard !writer.gone else { return false }
        writer.write(message)
        return true
    }

    func detach(connectionId: UUID) {
        lock.lock()
        detachList.append(connectionId)
        let writer = writers.removeValue(forKey: connectionId)
        lock.unlock()
        guard let writer else { return }
        // Waits for a write in progress, as the hub does.
        writer.calling.lock()
        writer.gone = true
        writer.calling.unlock()
    }

    func send(session: String, bytes: [UInt8]) {
        lock.lock(); inputList.append(Input(session: session, bytes: bytes)); lock.unlock()
    }

    func resync(connectionId: UUID, onUnavailable: @escaping @Sendable () -> Void) {
        onUnavailable()
    }

    func claim(connectionId: UUID, cols: Int, rows: Int) {
        lock.lock(); claimList.append(Claim(id: connectionId, cols: cols, rows: rows)); lock.unlock()
    }

    func stop() {}
}

/// A viewer on the other end of the socket, as the pane's bridge will be.
private final class Client: @unchecked Sendable {
    let fd: Int32
    private var reader = StreamFrameReader()
    private var pending: [StreamMessage] = []
    private var open = true

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var suppress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw TerminalRelayError.socketFailed(code)
        }
    }
    deinit { close() }

    func close() {
        guard open else { return }
        open = false
        Darwin.close(fd)
    }

    @discardableResult
    func sendRaw(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    @discardableResult
    func send(_ message: StreamMessage) -> Bool {
        sendRaw(StreamCodec.socketFrame(for: message))
    }

    func hello(session: String? = "s1", resize: ResizeMode? = nil, version: Int = 2) {
        send(.hello(protocolVersion: version, session: session, resize: resize))
    }

    /// The next message, or nil when the socket ends or nothing comes in time.
    func next(within seconds: Double = 5) -> StreamMessage? {
        let deadline = Date().addingTimeInterval(seconds)
        while pending.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, Int32(min(remaining, 0.2) * 1000)) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            guard let messages = try? reader.append(Array(buffer[0..<count])) else { return nil }
            pending += messages
        }
        return pending.removeFirst()
    }

    /// The next `count` messages, or fewer if the socket ends first.
    func next(_ count: Int, within seconds: Double = 5) -> [StreamMessage] {
        var messages: [StreamMessage] = []
        while messages.count < count, let message = next(within: seconds) { messages.append(message) }
        return messages
    }

    /// Whether the server closed the socket with nothing more sent, within `seconds`.
    func endsWithNothing(within seconds: Double = 5) -> Bool {
        guard pending.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, 200) > 0 else { continue }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            return count <= 0
        }
        return false
    }
}

/// The server end of the pane's local socket, on real sockets in the temp directory.
@Suite struct LocalStreamServerTests {
    private static func path() -> String {
        // Short: `sun_path` is 104 bytes, and the temp directory spends about half.
        NSTemporaryDirectory() + "lst-\(UUID().uuidString.prefix(8)).sock"
    }

    private func server(_ streamer: LocalFakeStreamer, path: String = LocalStreamServerTests.path(),
                        helloTimeout: TimeInterval = 5,
                        peerCheck: @escaping @Sendable (Int32) -> Bool = LocalStreamServer.isSameUser)
        throws -> LocalStreamServer {
        let server = try LocalStreamServer(path: path, streamer: streamer,
                                           helloTimeout: helloTimeout, peerCheck: peerCheck)
        server.start()
        return server
    }

    private func flags(_ fd: Int32) -> Int32 { fcntl(fd, F_GETFD) }

    private func option(_ fd: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, name, &value, &length)
        return value
    }

    /// Attaches one client to `session` and reads past its hello, resize and snapshot.
    private func attached(_ streamer: LocalFakeStreamer, _ server: LocalStreamServer,
                          session: String = "s1") throws -> (Client, UUID) {
        let client = try Client(path: server.path)
        client.hello(session: session)
        let first = client.next(3)
        #expect(first.count == 3)
        #expect(eventually { streamer.attaches.contains { $0.session == session } })
        let id = try #require(streamer.attaches.last { $0.session == session }?.id)
        return (client, id)
    }

    // MARK: Listening

    @Test func theSocketFileIsForItsOwnerAlone() throws {
        // A directory of its own, so its listing holds nothing of another test.
        var template = Array((NSTemporaryDirectory() + "lsdXXXXXX").utf8CString)
        let directory = String(cString: try #require(mkdtemp(&template)))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let streamer = LocalFakeStreamer()
        let server = try server(streamer, path: directory + "/wty-1.sock")
        defer { server.stop() }
        var info = stat()
        #expect(lstat(server.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        // Nothing is left of the private directory the socket was bound in.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["wty-1.sock"])
        // And the renamed socket is the one that answers.
        let (client, _) = try attached(streamer, server)
        client.close()
    }

    @Test func theListenerIsClosedOnExecAndNeverRaisesSigpipe() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let fd = server.listeningDescriptor
        #expect(fd >= 0)
        #expect(flags(fd) & FD_CLOEXEC != 0)
        #expect(option(fd, SO_NOSIGPIPE) != 0)
    }

    @Test func anAcceptedSocketIsClosedOnExecBlockingAndHasRoomForControlMessages() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let (client, _) = try attached(streamer, server)
        defer { client.close() }
        let fds = server.connectionDescriptors
        #expect(fds.count == 1)
        let fd = try #require(fds.first)
        #expect(flags(fd) & FD_CLOEXEC != 0)
        #expect(option(fd, SO_NOSIGPIPE) != 0)
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK == 0)
        let granted = option(fd, SO_SNDBUF)
        print("MEASURE local stream server SO_SNDBUF granted \(granted) bytes")
        #expect(granted >= LocalStreamServer.sendBufferSize)
    }

    @Test func aStaleFileAtThePathIsReplaced() throws {
        let path = Self.path()
        FileManager.default.createFile(atPath: path, contents: Data([1, 2, 3]))
        let streamer = LocalFakeStreamer()
        let server = try server(streamer, path: path)
        defer { server.stop() }
        let (client, _) = try attached(streamer, server)
        client.close()
    }

    @Test func stopUnlinksThePathAndClosesEveryConnection() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        let (one, oneId) = try attached(streamer, server, session: "a")
        let (two, twoId) = try attached(streamer, server, session: "b")

        server.stop()

        var info = stat()
        #expect(lstat(server.path, &info) != 0)
        #expect(one.endsWithNothing())
        #expect(two.endsWithNothing())
        #expect(eventually { Set(streamer.detaches) == [oneId, twoId] })
        #expect(eventually { server.connectionDescriptors.isEmpty })
        #expect((try? Client(path: server.path)) == nil)
        server.stop()
    }

    // MARK: Peer check

    @Test func theRealPeerCheckAcceptsThisUser() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        #expect(LocalStreamServer.isSameUser(pair[0]))
    }

    @Test func aPeerThatFailsTheCheckIsClosedBeforeAByteIsRead() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer, peerCheck: { _ in false })
        defer { server.stop() }
        let client = try Client(path: server.path)
        client.hello()
        #expect(client.endsWithNothing())
        Thread.sleep(forTimeInterval: 0.1)
        #expect(streamer.attaches.isEmpty)
    }

    // MARK: The hello

    private func refused(with frame: [UInt8], code: String) throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let client = try Client(path: server.path)
        client.sendRaw(frame)
        guard case .error(let received, _)? = client.next() else {
            Issue.record("expected an error frame")
            return
        }
        #expect(received == code)
        #expect(client.endsWithNothing())
        Thread.sleep(forTimeInterval: 0.1)
        #expect(streamer.attaches.isEmpty)
    }

    @Test func aFirstFrameThatIsNotAHelloIsRefused() throws {
        try refused(with: StreamCodec.socketFrame(for: .data([0x41])), code: "hello")
    }

    @Test func aHelloWithoutASessionIsRefused() throws {
        try refused(with: StreamCodec.socketFrame(for: .hello(protocolVersion: 2, session: nil, resize: nil)),
                    code: "session")
    }

    @Test func aHelloOfAnotherVersionIsRefused() throws {
        try refused(with: StreamCodec.socketFrame(for: .hello(protocolVersion: 3, session: "s1", resize: nil)),
                    code: "protocol")
    }

    @Test func aFrameTheReaderRefusesBeforeTheHelloIsRefused() throws {
        // A zero length: not even a type byte.
        try refused(with: [0, 0, 0, 0], code: "hello")
    }

    @Test func aClientThatSaysNothingIsClosedWithNoReply() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer, helloTimeout: 0.3)
        defer { server.stop() }
        let client = try Client(path: server.path)
        #expect(client.endsWithNothing(within: 3))
        #expect(eventually { server.connectionDescriptors.isEmpty })
        #expect(streamer.attaches.isEmpty)
    }

    @Test func aHelloWithoutAResizeModeMeansReflow() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let client = try Client(path: server.path)
        client.hello(session: "s1", resize: nil)
        _ = client.next(3)
        let repaint = try Client(path: server.path)
        repaint.hello(session: "s2", resize: .repaint)
        _ = repaint.next(3)
        #expect(eventually { streamer.attaches.count == 2 })
        #expect(streamer.attaches.first { $0.session == "s1" }?.resize == .reflow)
        #expect(streamer.attaches.first { $0.session == "s2" }?.resize == .repaint)
    }

    @Test func theHelloIsAnsweredThenTheAttachThenTheStream() throws {
        let streamer = LocalFakeStreamer()
        streamer.onAttach = [.resize(cols: 100, rows: 30, own: false), .snapshot([0x1B, 0x63, 0x41])]
        let server = try server(streamer)
        defer { server.stop() }
        let client = try Client(path: server.path)
        client.hello(session: "s1")
        let first = client.next(3)
        #expect(first == [.hello(protocolVersion: 2, session: nil, resize: nil),
                          .resize(cols: 100, rows: 30, own: false),
                          .snapshot([0x1B, 0x63, 0x41])])
        let id = try #require(streamer.attaches.first?.id)
        #expect(streamer.deliver(.data([0x42, 0x43]), to: id))
        #expect(client.next() == .data([0x42, 0x43]))
    }

    @Test func anEndedSessionGetsEndedAndIsClosed() throws {
        let streamer = LocalFakeStreamer()
        streamer.endsOnAttach = true
        let server = try server(streamer)
        defer { server.stop() }
        let client = try Client(path: server.path)
        client.hello(session: "gone")
        #expect(client.next(2) == [.hello(protocolVersion: 2, session: nil, resize: nil), .ended])
        #expect(client.endsWithNothing())
        #expect(eventually { server.connectionDescriptors.isEmpty })
    }

    @Test func anEndedViewerIsClosedAfterItsEnded() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let (client, id) = try attached(streamer, server)
        streamer.deliver(.ended, to: id)
        #expect(client.next() == .ended)
        #expect(client.endsWithNothing())
        #expect(eventually { streamer.detaches == [id] })
    }

    // MARK: Reading

    @Test func inputAndClaimsReachTheStreamer() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let client = try Client(path: server.path)
        // The hello and what follows in one write: nothing after the hello is lost.
        client.sendRaw(StreamCodec.socketFrame(for: .hello(protocolVersion: 2, session: "s1", resize: nil))
                       + StreamCodec.socketFrame(for: .data([0x61])))
        _ = client.next(3)
        let id = try #require(streamer.attaches.first?.id)
        client.send(.resize(cols: 120, rows: 40, own: false))
        client.send(.data([0x62]))
        #expect(eventually { streamer.inputs.count == 2 && streamer.claims.count == 1 })
        #expect(streamer.inputs == [.init(session: "s1", bytes: [0x61]), .init(session: "s1", bytes: [0x62])])
        #expect(streamer.claims == [.init(id: id, cols: 120, rows: 40)])
    }

    @Test func bytesAreExactInBothDirections() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let (client, id) = try attached(streamer, server)
        let invalid: [UInt8] = [0xC3, 0x28]
        let large = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }

        client.send(.data(invalid))
        client.send(.data(large))
        #expect(eventually { streamer.inputs.count == 2 })
        #expect(streamer.inputs.map(\.bytes) == [invalid, large])

        let writer = Background { streamer.deliver(.data(invalid), to: id); streamer.deliver(.data(large), to: id) }
        #expect(client.next() == .data(invalid))
        #expect(client.next() == .data(large))
        #expect(writer.wait())
    }

    @Test func aFrameTheReaderRefusesClosesWithNoReply() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let (client, id) = try attached(streamer, server)
        // A length one byte over the 1 MiB a viewer may send.
        let length = UInt32((1 << 20) + 2)
        client.sendRaw([UInt8(length >> 24), UInt8((length >> 16) & 0xFF),
                        UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), 0x02])
        #expect(client.endsWithNothing())
        #expect(eventually { streamer.detaches == [id] })
        #expect(streamer.inputs.isEmpty)
    }

    // MARK: Writing and disconnecting

    /// Writes 256 KiB messages to a viewer that does not read until one blocks.
    /// Returns the writer and how many messages it had begun.
    private func fill(_ streamer: LocalFakeStreamer, _ id: UUID) -> (Background, () -> Int) {
        let counter = NSLock()
        nonisolated(unsafe) var begun = 0
        let chunk = [UInt8](repeating: 0x5A, count: 256 << 10)
        let writer = Background {
            while true {
                counter.lock(); begun += 1; counter.unlock()
                guard streamer.deliver(.data(chunk), to: id) else { return }
            }
        }
        return (writer, { counter.lock(); defer { counter.unlock() }; return begun })
    }

    /// Whether the count stops moving: a write is blocked.
    private func stalls(_ count: () -> Int) -> Bool {
        var last = -1
        return eventually(within: 10) {
            let now = count()
            defer { last = now }
            guard now == last else { Thread.sleep(forTimeInterval: 0.3); return false }
            return true
        }
    }

    @Test func aClientThatStopsReadingBlocksTheWriteUntilItReads() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let (client, id) = try attached(streamer, server)
        let (writer, begun) = fill(streamer, id)
        #expect(stalls(begun))
        #expect(!writer.hasFinished)
        // Reading lets it go on: everything written so far arrives whole and in order.
        let before = begun()
        for _ in 0..<(before + 1) {
            #expect(client.next() == .data([UInt8](repeating: 0x5A, count: 256 << 10)))
        }
        #expect(begun() > before)
        client.close()
        #expect(writer.wait())
    }

    @Test func aClientThatDisconnectsReleasesABlockedWriteAndIsDetachedOnce() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let (client, id) = try attached(streamer, server)
        let (writer, begun) = fill(streamer, id)
        #expect(stalls(begun))

        client.close()

        #expect(writer.wait())
        #expect(eventually { streamer.detaches == [id] })
        #expect(eventually { server.connectionDescriptors.isEmpty })
        Thread.sleep(forTimeInterval: 0.2)
        #expect(streamer.detaches == [id])
    }

    @Test func stopReleasesABlockedWriteWithoutWaitingForIt() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        let (client, id) = try attached(streamer, server)
        defer { client.close() }
        let (writer, begun) = fill(streamer, id)
        #expect(stalls(begun))

        let started = Date()
        server.stop()
        #expect(Date().timeIntervalSince(started) < 1)

        #expect(writer.wait())
        #expect(eventually { streamer.detaches == [id] })
    }

    /// A client that never reads its snapshot holds the thread that attached it,
    /// and both its own going away and `stop` still end it.
    @Test func aClientThatNeverReadsItsSnapshotCanStillBeEnded() throws {
        for byStop in [false, true] {
            let streamer = LocalFakeStreamer()
            streamer.onAttach = [.resize(cols: 80, rows: 24, own: false),
                                 .snapshot([UInt8](repeating: 0x41, count: 8 << 20))]
            let server = try server(streamer)
            let client = try Client(path: server.path)
            client.hello()
            #expect(eventually { streamer.attaches.count == 1 })
            Thread.sleep(forTimeInterval: 0.3)
            #expect(streamer.attachesReturned == 0)

            if byStop { server.stop() } else { client.close() }

            #expect(eventually { streamer.attachesReturned == 1 })
            let id = try #require(streamer.attaches.first?.id)
            #expect(eventually { streamer.detaches == [id] })
            #expect(eventually { server.connectionDescriptors.isEmpty })
            server.stop()
            client.close()
        }
    }

    @Test func severalClientsAttachToDifferentSessionsAtOnce() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let sessions = ["a", "b", "c"]
        var clients: [(String, Client, UUID)] = []
        for session in sessions {
            let (client, id) = try attached(streamer, server, session: session)
            clients.append((session, client, id))
        }
        #expect(server.connectionDescriptors.count == 3)
        for (session, client, id) in clients {
            streamer.deliver(.data(Array(session.utf8)), to: id)
            #expect(client.next() == .data(Array(session.utf8)))
            client.send(.data(Array(session.utf8)))
        }
        #expect(eventually { streamer.inputs.count == 3 })
        #expect(Set(streamer.inputs) == Set(sessions.map { .init(session: $0, bytes: Array($0.utf8)) }))
    }

    // MARK: The operating system

    /// The disconnect design rests on this: a write blocked on a full Unix socket
    /// returns once another thread shuts the socket down.
    @Test func shutdownReleasesAWriteBlockedOnAFullSocket() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let fd = pair[0]
        var suppress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
        let counter = NSLock()
        nonisolated(unsafe) var written = 0
        nonisolated(unsafe) var failure: Int32 = 0
        let writer = Background {
            let chunk = [UInt8](repeating: 1, count: 1 << 10)
            while true {
                let count = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    let code = errno
                    counter.lock(); failure = code; counter.unlock()
                    return
                }
                counter.lock(); written += count; counter.unlock()
            }
        }
        #expect(stalls { counter.lock(); defer { counter.unlock() }; return written })
        #expect(!writer.hasFinished)

        let started = Date()
        shutdown(fd, SHUT_RDWR)
        #expect(writer.wait(2))
        let elapsed = Date().timeIntervalSince(started)
        counter.lock(); let code = failure; let total = written; counter.unlock()
        print("MEASURE shutdown released a write blocked after \(total) bytes in \(Int(elapsed * 1000)) ms, errno \(code)")
        #expect(code != 0)
        #expect(elapsed < 1)
    }
}
