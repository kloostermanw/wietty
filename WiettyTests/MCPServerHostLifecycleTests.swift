import Testing
import Foundation
@testable import Wietty

/// Starts real Hummingbird servers on loopback, unlike `MCPServerHostTests`, which
/// drives the transport without binding. What is under test here is the part the
/// transport tests cannot see: whether the port was bound, and what `status` says
/// about it. Every host asks for port 0 so the kernel picks a free one and no two
/// runs of the suite can collide.
@Suite(.serialized) @MainActor struct MCPServerHostLifecycleTests {
    private func makeHost(port: Int = 0,
                          onStatusChange: (@MainActor (MCPServerStatus) -> Void)? = nil) -> MCPServerHost {
        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 service: FakeTerminalService())
        return MCPServerHost(router: MCPToolRouter(store: store), port: port, onStatusChange: onStatusChange)
    }

    /// Polls `host.status` until `predicate` holds or five seconds pass. The bind
    /// completes on a NIO event loop, so there is no single call to await.
    private func waitFor(_ host: MCPServerHost,
                         _ predicate: (MCPServerStatus) -> Bool) async -> MCPServerStatus {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(host.status), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return host.status
    }

    private func runningPort(_ status: MCPServerStatus) -> Int? {
        if case let .running(port) = status { return port }
        return nil
    }

    @Test func aNewHostIsStopped() {
        #expect(makeHost().status == .stopped)
    }

    /// Running means bound: the status reports the port the kernel actually gave,
    /// not the 0 that was asked for, so the bar can show a real address.
    @Test func startReachesRunningOnTheBoundPort() async {
        let host = makeHost()
        await host.start()

        let status = await waitFor(host) { runningPort($0) != nil }

        let port = try? #require(runningPort(status))
        #expect((port ?? 0) > 0)
        await host.stop()
    }

    /// The case the issue is about: a port somebody else holds. Before, this only
    /// surfaced as text on the Settings tab.
    @Test func aTakenPortReachesFailed() async throws {
        let first = makeHost()
        await first.start()
        let port = try #require(runningPort(await waitFor(first) { runningPort($0) != nil }))

        let second = makeHost(port: port)
        await second.start()
        let status = await waitFor(second) { if case .failed = $0 { true } else { false } }

        guard case let .failed(failedPort, message) = status else {
            Issue.record("expected failed, got \(status)")
            return
        }
        #expect(failedPort == port)
        #expect(!message.isEmpty)
        await first.stop()
    }

    @Test func stopReportsStopped() async {
        let host = makeHost()
        await host.start()
        _ = await waitFor(host) { runningPort($0) != nil }

        await host.stop()

        #expect(host.status == .stopped)
    }

    /// A restart on the same port binds again. Restart is what the status bar's
    /// button does. `stop` awaits the old server before returning, so this does not
    /// depend on how fast the old socket closes, though on this machine it closes in
    /// time either way and this test does not catch the await being removed.
    @Test func restartOnTheSamePortRunsAgain() async throws {
        let host = makeHost()
        await host.start()
        let port = try #require(runningPort(await waitFor(host) { runningPort($0) != nil }))

        await host.restart(port: port)
        let status = await waitFor(host) { runningPort($0) != nil }

        #expect(runningPort(status) == port)
        await host.stop()
    }

    /// A clean stop reports only `stopped`. The server's run task ends as it is
    /// cancelled, and without the generation check its "the server stopped" failure
    /// would flash in the bar on every restart.
    @Test func aStopNeverReportsAFailure() async throws {
        var reported: [MCPServerStatus] = []
        let host = makeHost(onStatusChange: { reported.append($0) })
        await host.start()
        let port = try #require(runningPort(await waitFor(host) { runningPort($0) != nil }))

        await host.stop()
        try await Task.sleep(for: .milliseconds(200))

        #expect(reported == [.starting(port: 0), .running(port: port), .stopped])
    }

    /// Two Restart clicks in a row start two overlapping restarts. Afterwards the
    /// host is running and a `stop` frees the port, so no second server was left
    /// holding it. This pins the outcome; it did not reproduce the interleaving the
    /// generation check after `makeStartedServer` guards against.
    @Test func overlappingRestartsLeaveOneServer() async throws {
        let host = makeHost()
        await host.start()
        let port = try #require(runningPort(await waitFor(host) { runningPort($0) != nil }))

        async let first: Void = host.restart(port: port)
        async let second: Void = host.restart(port: port)
        _ = await (first, second)
        _ = await waitFor(host) { runningPort($0) != nil }
        #expect(runningPort(host.status) == port)

        // If a second server were left over, it would keep the port after this.
        await host.stop()
        let probe = makeHost(port: port)
        await probe.start()
        let status = await waitFor(probe) { runningPort($0) != nil }
        #expect(runningPort(status) == port)
        await probe.stop()
    }

    /// The server the restart replaced must not report into the new one. The
    /// callback is the only path the status takes into the store, so the last value
    /// it delivers is what the bar shows.
    @Test func theLastReportedStatusIsTheCurrentOne() async throws {
        var reported: [MCPServerStatus] = []
        let host = makeHost(onStatusChange: { reported.append($0) })
        await host.start()
        let port = try #require(runningPort(await waitFor(host) { runningPort($0) != nil }))

        await host.restart(port: port)
        _ = await waitFor(host) { runningPort($0) != nil }
        try await Task.sleep(for: .milliseconds(200))

        #expect(reported.last == .running(port: port))
        #expect(reported.last == host.status)
        await host.stop()
    }
}

/// What the status bar shows for each status. Kept on the status rather than the
/// view so it is testable without rendering anything.
@Suite struct MCPServerStatusPresentationTests {
    @Test func runningShowsTheEndpoint() {
        let status = MCPServerStatus.running(port: 7433)
        #expect(status.summary == "MCP 127.0.0.1:7433")
        #expect(status.health == .ok)
        #expect(status.endpointURL == "http://127.0.0.1:7433/mcp")
    }

    @Test func startingIsPending() {
        let status = MCPServerStatus.starting(port: 7433)
        #expect(status.summary == "MCP starting")
        #expect(status.health == .pending)
        #expect(status.endpointURL == nil)
    }

    @Test func failedCarriesTheReasonInTheDetail() {
        let status = MCPServerStatus.failed(port: 7433, message: "Address already in use")
        #expect(status.summary == "MCP not running")
        #expect(status.health == .error)
        #expect(status.detail.contains("Address already in use"))
        #expect(status.detail.contains("7433"))
    }

    @Test func stoppedIsAnError() {
        #expect(MCPServerStatus.stopped.summary == "MCP stopped")
        #expect(MCPServerStatus.stopped.health == .error)
    }

    @Test func onlyAFailureHasAnErrorMessage() {
        #expect(MCPServerStatus.failed(port: 1, message: "boom").errorMessage == "boom")
        #expect(MCPServerStatus.running(port: 1).errorMessage == nil)
        #expect(MCPServerStatus.stopped.errorMessage == nil)
    }
}
