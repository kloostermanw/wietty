import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// What a link delivered, recorded, and an optional gate its `onMessage` waits on.
private final class LinkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messageList: [StreamMessage] = []
    private var endList: [TerminalEndReason] = []
    private var blocked: DispatchSemaphore?
    private var insideCount = 0

    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return messageList }
    var ends: [TerminalEndReason] { lock.lock(); defer { lock.unlock() }; return endList }
    /// Callbacks that have started and not returned.
    var inside: Int { lock.lock(); defer { lock.unlock() }; return insideCount }

    /// From now on, every `onMessage` waits on `gate` (at most ten seconds, so a
    /// broken test ends) after recording its message.
    func block(on gate: DispatchSemaphore) { lock.lock(); blocked = gate; lock.unlock() }
    func unblock() { lock.lock(); blocked = nil; lock.unlock() }

    func attach(to link: LocalSocketLink) {
        link.onMessage = { [self] message in
            lock.lock()
            messageList.append(message)
            insideCount += 1
            let gate = blocked
            lock.unlock()
            _ = gate?.wait(timeout: .now() + 10)
            lock.lock(); insideCount -= 1; lock.unlock()
        }
        link.onEnded = { [self] reason in
            lock.lock(); endList.append(reason); lock.unlock()
        }
    }
}

/// A server that is not `LocalStreamServer`, for what the real one never does: it
/// writes `frames` to the first client, then records what the client sends until it
/// closes.
private final class ScriptedServer: @unchecked Sendable {
    let path: String
    private let listenFd: Int32
    private let lock = NSLock()
    private var received: [UInt8] = []
    private var closed = false
    private var call: BackgroundCall?

    init(frames: [StreamMessage]) throws {
        path = shortSocketPath("lss")
        unlink(path)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listenFd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFd, 1) == 0 else {
            let code = errno
            Darwin.close(listenFd)
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let listener = listenFd
        call = BackgroundCall { [self] in
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let client = UnixTestSocket(accepted: fd)
            for frame in frames { client.write(StreamCodec.socketFrame(for: frame)) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                lock.lock(); received += buffer[0..<count]; lock.unlock()
            }
            lock.lock(); closed = true; lock.unlock()
        }
    }

    /// Every message the client sent, once it has closed; nil if it has not within `seconds`.
    func messagesAfterClose(within seconds: Double = 5) -> [StreamMessage]? {
        guard waitUntil(within: seconds, { lock.lock(); defer { lock.unlock() }; return closed }) else {
            return nil
        }
        lock.lock(); let bytes = received; lock.unlock()
        var reader = StreamFrameReader()
        return try? reader.append(bytes)
    }

    func stop() {
        Darwin.close(listenFd)
        unlink(path)
    }
}

/// The pane's client of `LocalStreamServer`, on real sockets in the temp directory.
@Suite struct LocalSocketLinkTests {
    private func server(_ streamer: LocalFakeStreamer) throws -> LocalStreamServer {
        let server = try LocalStreamServer(path: shortSocketPath("lsl"), streamer: streamer)
        server.start()
        return server
    }

    /// A started link on `session`, whose first attach is recorded by the fake.
    private func started(_ server: LocalStreamServer, _ streamer: LocalFakeStreamer,
                         _ recorder: LinkRecorder, session: String = "s1") -> LocalSocketLink {
        let link = LocalSocketLink(path: server.path, session: session)
        recorder.attach(to: link)
        link.start()
        return link
    }

    @Test func itSaysHelloFirstWithItsSessionAndReflow() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let link = started(server, streamer, recorder, session: "gt:abc")
        defer { link.stop() }
        // The server attaches only after a first frame that is a version 2 hello
        // naming the session; anything else it refuses.
        #expect(waitUntil { streamer.attaches.count == 1 })
        #expect(streamer.attaches.first?.session == "gt:abc")
        #expect(streamer.attaches.first?.resize == .reflow)
        #expect(recorder.ends.isEmpty)
    }

    @Test func itDeliversTheStreamInOrderAndEndsAsSessionEndedOnEnded() throws {
        let streamer = LocalFakeStreamer()
        streamer.onAttach = [.resize(cols: 80, rows: 24, own: false), .snapshot([0x1B, 0x63, 0xFF])]
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let link = started(server, streamer, recorder)
        defer { link.stop() }
        #expect(waitUntil { streamer.attachesReturned == 1 })
        let id = try #require(streamer.attaches.first?.id)
        streamer.deliver(.data([0xC3, 0x28, 0x00]), to: id)
        streamer.deliver(.repaint([0x41]), to: id)
        streamer.deliver(.ended, to: id)
        #expect(waitUntil { recorder.ends == [.sessionEnded] })
        // The server's hello is consumed, never delivered; `ended` is the end, not a message.
        #expect(recorder.messages == [.resize(cols: 80, rows: 24, own: false), .snapshot([0x1B, 0x63, 0xFF]),
                                      .data([0xC3, 0x28, 0x00]), .repaint([0x41])])
    }

    @Test func anErrorEndsItAsRefused() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        // The server refuses a hello that names no session.
        let link = started(server, streamer, recorder, session: "")
        defer { link.stop() }
        #expect(waitUntil { !recorder.ends.isEmpty })
        guard case .refused(let code, _)? = recorder.ends.first else {
            Issue.record("ended as \(recorder.ends)")
            return
        }
        #expect(code == "session")
        #expect(recorder.ends.count == 1)
        #expect(recorder.messages.isEmpty)
    }

    @Test func aClosedSocketEndsItAsConnectionLost() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        let recorder = LinkRecorder()
        let link = started(server, streamer, recorder)
        defer { link.stop() }
        #expect(waitUntil { recorder.messages.count == 2 })
        server.stop()
        #expect(waitUntil { recorder.ends == [.connectionLost] })
    }

    @Test func noServerAtThePathEndsItAsConnectionLost() {
        let link = LocalSocketLink(path: shortSocketPath("lsn"), session: "s1")
        let recorder = LinkRecorder()
        recorder.attach(to: link)
        link.start()
        defer { link.stop() }
        #expect(waitUntil { recorder.ends == [.connectionLost] })
    }

    /// The real server always answers `hello` first, so this one is scripted.
    @Test func aFirstFrameThatIsNotHelloEndsItAsServerTooOld() throws {
        let fake = try ScriptedServer(frames: [.resize(cols: 80, rows: 24, own: false)])
        defer { fake.stop() }
        let link = LocalSocketLink(path: fake.path, session: "s1")
        let recorder = LinkRecorder()
        recorder.attach(to: link)
        link.start()
        defer { link.stop() }
        #expect(waitUntil { recorder.ends == [.serverTooOld] })
        #expect(recorder.messages.isEmpty)
    }

    @Test func aNewerHelloEndsItAsRefused() throws {
        let fake = try ScriptedServer(frames: [.hello(protocolVersion: 3, session: nil, resize: nil)])
        defer { fake.stop() }
        let link = LocalSocketLink(path: fake.path, session: "s1")
        let recorder = LinkRecorder()
        recorder.attach(to: link)
        link.start()
        defer { link.stop() }
        #expect(waitUntil { !recorder.ends.isEmpty })
        guard case .refused(let code, _)? = recorder.ends.first else {
            Issue.record("ended as \(recorder.ends)")
            return
        }
        #expect(code == "protocol")
    }

    /// The pane's losslessness rests on this: while `onMessage` has not returned,
    /// nothing more is read, so the socket fills and the server's blocking write
    /// waits. Shown by output far larger than both socket buffers, whose delivery on
    /// the server's side does not finish until the callback is released.
    @Test func aBlockingOnMessageStopsTheReading() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let gate = DispatchSemaphore(value: 0)
        recorder.block(on: gate)
        let link = started(server, streamer, recorder)
        defer { link.stop() }
        // The attach's resize is delivered and held. The snapshot after it is written
        // to the socket, but the link must not read it yet.
        #expect(waitUntil { recorder.inside == 1 })
        #expect(waitUntil { streamer.attachesReturned == 1 })
        let id = try #require(streamer.attaches.first?.id)

        let chunk = [UInt8](repeating: 0x61, count: 64 << 10)
        let count = 64   // 4 MiB, against 256 KiB of send buffer and a receive buffer
        let delivery = BackgroundCall {
            for _ in 0..<count { streamer.deliver(.data(chunk), to: id) }
        }
        // The server's writes cannot all land while the link is not reading.
        #expect(!delivery.wait(1))
        #expect(recorder.messages.count == 1)

        recorder.unblock()
        for _ in 0..<4 { gate.signal() }
        #expect(delivery.wait(10))
        #expect(waitUntil(within: 10) { recorder.messages.count == 2 + count })
        #expect(recorder.messages.dropFirst(2).allSatisfy { $0 == .data(chunk) })
    }

    /// Input goes out in frames of at most 64 KiB, in order, and each claim as one
    /// `resize`. The fake records one input per `data` frame the server read.
    @Test func sendSplitsIntoFramesOfAtMost64KiBAndClaimWritesOneResize() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let link = started(server, streamer, recorder)
        defer { link.stop() }
        #expect(waitUntil { streamer.attachesReturned == 1 })
        let id = try #require(streamer.attaches.first?.id)
        let big = (0..<150_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        link.send([0x61, 0x62])
        link.send(big)
        link.send([0xC3, 0x28])
        link.claim(cols: 120, rows: 40)
        #expect(waitUntil { streamer.inputs.count == 5 && streamer.claims.count == 1 })
        let max = LocalSocketLink.maxInputFrame
        #expect(streamer.inputs.map(\.bytes) == [[0x61, 0x62], Array(big[0..<max]),
                                                 Array(big[max..<(2 * max)]), Array(big[(2 * max)...]),
                                                 [0xC3, 0x28]])
        #expect(streamer.inputs.allSatisfy { $0.session == "s1" })
        #expect(streamer.claims == [.init(id: id, cols: 120, rows: 40)])
    }

    /// The bridge claims from the main actor, and the server reads nothing while it
    /// writes a snapshot to a pane that is not reading. Neither `send` nor `claim`
    /// may wait for that: they queue. Shown by a writer blocked on a full socket.
    @Test func sendAndClaimNeverBlockOnAServerThatIsNotReading() throws {
        let streamer = LocalFakeStreamer()
        // A snapshot far larger than both socket buffers: the server's reading thread
        // stays inside the attach, writing it, while the link holds its first message.
        let snapshot = [UInt8](repeating: 0x73, count: 4 << 20)
        streamer.onAttach = [.resize(cols: 80, rows: 24, own: false), .snapshot(snapshot)]
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let gate = DispatchSemaphore(value: 0)
        recorder.block(on: gate)
        let link = started(server, streamer, recorder)
        defer { link.stop() }
        #expect(waitUntil { recorder.inside == 1 })
        #expect(streamer.attachesReturned == 0)

        // More input than the socket holds: the link's writer blocks on it.
        let input = [UInt8](repeating: 0x69, count: 4 << 20)
        let sending = BackgroundCall { link.send(input) }
        #expect(sending.wait(1))
        let claiming = BackgroundCall { link.claim(cols: 100, rows: 30) }
        #expect(claiming.wait(1))

        recorder.unblock()
        gate.signal()
        #expect(waitUntil(within: 10) { streamer.claims.count == 1 })
        #expect(Array(streamer.inputs.map(\.bytes).joined()) == input)
        #expect(streamer.claims.first?.cols == 100)
    }

    @Test func sendAndClaimBeforeStartAreDropped() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let link = LocalSocketLink(path: server.path, session: "s1")
        defer { link.stop() }
        link.send([0x01])
        link.claim(cols: 100, rows: 30)
        link.start()
        #expect(waitUntil { streamer.attachesReturned == 1 })
        link.send([0x02])
        #expect(waitUntil { !streamer.inputs.isEmpty })
        #expect(streamer.inputs.map(\.bytes) == [[0x02]])
        #expect(streamer.claims.isEmpty)
    }

    /// Scripted, so what reaches the other end after the end can be seen: only the hello.
    @Test func sendAndClaimAfterAnEndAreDropped() throws {
        let fake = try ScriptedServer(frames: [.hello(protocolVersion: 2, session: nil, resize: nil), .ended])
        defer { fake.stop() }
        let link = LocalSocketLink(path: fake.path, session: "s1")
        let recorder = LinkRecorder()
        recorder.attach(to: link)
        link.start()
        defer { link.stop() }
        #expect(waitUntil { recorder.ends == [.sessionEnded] })
        link.send([0x01])
        link.claim(cols: 100, rows: 30)
        let sent = try #require(fake.messagesAfterClose())
        #expect(sent == [.hello(protocolVersion: 2, session: "s1", resize: .reflow)])
    }

    @Test func stopClosesTheSocketFiresNoEndAndDeliversNothingAfter() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let link = started(server, streamer, recorder)
        #expect(waitUntil { recorder.messages.count == 2 })
        let id = try #require(streamer.attaches.first?.id)
        link.stop()
        // The server sees the close and detaches the viewer.
        #expect(waitUntil { streamer.detaches == [id] })
        streamer.deliver(.data([0x01]), to: id)
        Thread.sleep(forTimeInterval: 0.2)   // room for a late delivery to show
        #expect(recorder.messages.count == 2)
        #expect(recorder.ends.isEmpty)
        link.stop()   // idempotent
    }

    /// `stop` from another thread waits for a callback in progress, so that once it
    /// has returned nothing of this link runs.
    @Test func stopWaitsForACallbackInProgress() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let recorder = LinkRecorder()
        let gate = DispatchSemaphore(value: 0)
        recorder.block(on: gate)
        let link = started(server, streamer, recorder)
        #expect(waitUntil { recorder.inside == 1 })
        let stopping = BackgroundCall { link.stop() }
        #expect(!stopping.wait(0.3))
        recorder.unblock()
        gate.signal()
        #expect(stopping.wait())
        #expect(recorder.inside == 0)
        // The snapshot was already on the socket; it is never delivered.
        Thread.sleep(forTimeInterval: 0.2)   // room for a late delivery to show
        #expect(recorder.messages.count == 1)
        #expect(recorder.ends.isEmpty)
    }

    /// From inside its own callback, `stop` cannot wait for that callback, and returns.
    @Test func stopFromInsideACallbackReturns() throws {
        let streamer = LocalFakeStreamer()
        let server = try server(streamer)
        defer { server.stop() }
        let link = LocalSocketLink(path: server.path, session: "s1")
        let stopped = DispatchSemaphore(value: 0)
        let count = Counter()
        link.onMessage = { [link] _ in
            count.increment()
            link.stop()
            stopped.signal()
        }
        link.start()
        #expect(stopped.wait(timeout: .now() + 5) == .success)
        #expect(waitUntil { streamer.detaches.count == 1 })
        #expect(count.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
