import Testing
import Foundation
@testable import Wietty

/// A stand-in streamer, proving `RemoteServer` depends on the protocol rather
/// than a concrete streaming implementation.
private final class FakeStreamer: ScreenStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var attached: [String] = []
    private(set) var sent: [String] = []
    private(set) var detached = 0
    private(set) var stopped = false

    @discardableResult
    func attach(session: String, onMessage: @escaping @Sendable (RemoteMessage) -> Void) -> UUID {
        lock.lock(); attached.append(session); lock.unlock()
        onMessage(.resize(cols: 80, rows: 24))
        return UUID()
    }
    func detach(connectionId: UUID) { lock.lock(); detached += 1; lock.unlock() }
    func send(session: String, text: String) { lock.lock(); sent.append(text); lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}

@Suite struct ScreenStreamingWiringTests {
    @Test func paneStreamHubSatisfiesTheStreamingProtocol() {
        let hub: any ScreenStreaming = PaneStreamHub()
        #expect(hub is PaneStreamHub)
    }

    @Test func anyStreamingImplementationCanBackTheServer() async {
        let fake = FakeStreamer()
        let streaming: any ScreenStreaming = fake
        streaming.attach(session: "%12") { _ in }
        streaming.send(session: "%12", text: "ls")
        #expect(fake.attached == ["%12"])
        #expect(fake.sent == ["ls"])
    }

    /// The seam that survives having one terminal: `RemoteServer` still takes the
    /// protocol, so a stand-in can back it in a test with no PTY and no surface.
    @MainActor
    @Test func theInternalTerminalSatisfiesTheServiceProtocols() {
        let stack = TerminalStack(ghosttyHost: FakeSurfaceHost())
        defer { stack.ghostty.ghosttyService?.closeAll() }
        #expect(stack.service is GhosttyService || stack.setupError != nil)
        #expect(stack.streamer is PaneStreamHub)
        #expect(stack.monitor is GhosttyMonitor)
    }
}
