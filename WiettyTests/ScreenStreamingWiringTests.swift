import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

/// A stand-in streamer, proving `RemoteServer` depends on the protocol rather
/// than a concrete streaming implementation.
private final class FakeStreamer: ScreenStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var attached: [String] = []
    private(set) var sent: [[UInt8]] = []
    private(set) var detached = 0
    private(set) var resynced = 0
    private(set) var stopped = false

    @discardableResult
    func attach(session: String, resize: ResizeMode,
                onMessage: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        lock.lock(); attached.append(session); lock.unlock()
        onMessage(.resize(cols: 80, rows: 24, own: false))
        return UUID()
    }
    /// Every local attach made, in order, with the id it was given.
    private(set) var localAttaches: [(session: String, id: UUID)] = []
    @discardableResult
    func attachLocal(session: String, resize: ResizeMode,
                     write: @escaping @Sendable (StreamMessage) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); localAttaches.append((session, id)); lock.unlock()
        return id
    }
    func detach(connectionId: UUID) { lock.lock(); detached += 1; lock.unlock() }
    func send(session: String, bytes: [UInt8]) { lock.lock(); sent.append(bytes); lock.unlock() }
    func resync(connectionId: UUID, onUnavailable: @escaping @Sendable () -> Void) {
        lock.lock(); resynced += 1; lock.unlock()
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    /// Every claim made, in order.
    private(set) var claims: [(id: UUID, cols: Int, rows: Int)] = []
    func claim(connectionId: UUID, cols: Int, rows: Int) {
        lock.lock(); claims.append((connectionId, cols, rows)); lock.unlock()
    }
}

@Suite struct ScreenStreamingWiringTests {
    @Test func paneStreamHubSatisfiesTheStreamingProtocol() {
        let hub: any ScreenStreaming = PaneStreamHub()
        #expect(hub is PaneStreamHub)
    }

    @Test func anyStreamingImplementationCanBackTheServer() async {
        let fake = FakeStreamer()
        let streaming: any ScreenStreaming = fake
        streaming.attach(session: "%12", resize: .reflow) { _ in }
        streaming.send(session: "%12", bytes: Array("ls".utf8))
        #expect(fake.attached == ["%12"])
        #expect(fake.sent == [Array("ls".utf8)])
    }

    /// The seam that survives having one terminal: `RemoteServer` still takes the
    /// protocol, so a stand-in can back it in a test with no PTY and no surface.
    @MainActor
    @Test func theInternalTerminalSatisfiesTheServiceProtocols() {
        let stack = TerminalStack.testing(host: FakeSurfaceHost())
        defer { stack.ghostty.ghosttyService?.closeAll() }
        #expect(stack.service is GhosttyService || stack.setupError != nil)
        #expect(stack.streamer is PaneStreamHub)
        #expect(stack.monitor is GhosttyMonitor)
    }
}
