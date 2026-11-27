import Foundation
import HTTPTypes
import Testing
import WiettyCore
@testable import Wietty

/// `POST /api/sessions/{sid}/stop`, the served side of the stop button on a row of
/// another Mac.
///
/// The route exists because `close` was the only way a viewer could end a session,
/// and `close` takes the row with it. A stop ends the child and leaves the row, its
/// last screen and its place in the list, which is what the stop button of a local
/// row does (`ProjectStore.stopTerminal`), and the route calls exactly that.
@Suite @MainActor struct RemoteStopRouteTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder() -> URL {
        let url = TestScratch.root
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("proj")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storeWithOneTerminal(_ fake: FakeTerminalService,
                                      defaults: UserDefaults? = nil) async -> ProjectStore {
        fake.handles = [TerminalHandle(sessionId: "%12", windowId: "win-1")]
        let store = ProjectStore(defaults: defaults ?? makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder())
        await store.openTerminal(for: store.projects[0])
        return store
    }

    // MARK: - The outcome

    /// The point of the route, and what tells it from `close`: the child is stopped
    /// and the row is still there, answered as the terminal object the other
    /// session routes answer with.
    @Test func aStopEndsTheSessionKeepsTheRowAndAnswersWithIt() async {
        let fake = FakeTerminalService()
        let store = await storeWithOneTerminal(fake)
        let ref = store.projects[0].terminals[0]

        let outcome = await RemoteServer.stopOutcome(store: store, sessionId: "%12")

        #expect(fake.stopCalls == ["%12"])
        #expect(fake.closeCalls.isEmpty)
        #expect(store.projects[0].terminals.map(\.id) == [ref.id])
        guard case let .ok(.object(members)) = outcome else {
            Issue.record("expected a terminal object, got \(outcome)")
            return
        }
        #expect(members["id"] == .string(ref.id.uuidString))
        // The row keeps its session id: a stop gives it no new session, unlike a
        // restart, so the stopped screen's Restart can still name it.
        #expect(members["session_id"] == .string("%12"))
    }

    /// A viewer whose snapshot is older than this Mac's rows, or a session a
    /// restart has replaced since.
    @Test func aSessionNoRowCarriesIsNotFound() async {
        let fake = FakeTerminalService()
        let store = await storeWithOneTerminal(fake)

        #expect(await RemoteServer.stopOutcome(store: store, sessionId: "%13") == .notFound)
        #expect(await RemoteServer.stopOutcome(store: store, sessionId: nil) == .notFound)
        #expect(fake.stopCalls.isEmpty)
    }

    /// A row that was never opened carries an empty session id, so an empty id
    /// would otherwise name the first such row. It names nothing.
    @Test func anEmptySessionIdMatchesNoRowEvenWhenARowHasNone() async {
        let fake = FakeTerminalService()
        // Opening fails, which leaves the row with the empty id of a row never opened.
        fake.openErrorToThrow = .failed("no terminal")
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder())
        await store.openTerminal(for: store.projects[0])

        #expect(await RemoteServer.stopOutcome(store: store, sessionId: "") == .notFound)
        #expect(fake.stopCalls.isEmpty)
    }

    /// A session that has already ended is answered like one that was running. The
    /// service does nothing for an exited terminal, and what was asked for holds.
    @Test func stoppingAnExitedSessionAnswersWithTheRowAgain() async {
        let fake = FakeTerminalService()
        let store = await storeWithOneTerminal(fake)
        let ref = store.projects[0].terminals[0]
        _ = await RemoteServer.stopOutcome(store: store, sessionId: "%12")
        // What the monitor reports once the child is gone.
        store.handle(.terminated(sessionId: "%12"))

        let outcome = await RemoteServer.stopOutcome(store: store, sessionId: "%12")

        guard case let .ok(.object(members)) = outcome else {
            Issue.record("expected a terminal object, got \(outcome)")
            return
        }
        #expect(members["id"] == .string(ref.id.uuidString))
        #expect(members["run_state"] == .string("exited"))
        #expect(store.projects[0].terminals.count == 1)
    }

    /// A remote stop is the user dealing with the row, as a local one is (issue
    /// #80), so the bell goes with it.
    @Test func aStopClearsTheRowsBell() async {
        let fake = FakeTerminalService()
        let store = await storeWithOneTerminal(fake)
        let ref = store.projects[0].terminals[0]
        store.handle(.bell(sessionId: "%12"))
        #expect(store.attention.contains(ref.id))

        let outcome = await RemoteServer.stopOutcome(store: store, sessionId: "%12")

        #expect(!store.attention.contains(ref.id))
        guard case let .ok(.object(members)) = outcome else {
            Issue.record("expected a terminal object, got \(outcome)")
            return
        }
        #expect(members["needs_attention"] == .bool(false))
    }

    @Test func eachOutcomeHasItsOwnStatus() {
        #expect(RemoteServer.StopOutcome.notFound.status == .notFound)
        #expect(RemoteServer.StopOutcome.notFound.body == nil)
        #expect(RemoteServer.StopOutcome.ok(.object([:])).status == .ok)
        #expect(RemoteServer.StopOutcome.ok(.object([:])).body == .object([:]))
    }

    // MARK: - The route itself

    /// The real route on a loopback port: the token is checked like its neighbours',
    /// the path's session id reaches the store undecoded (`%12` is a pane id, not an
    /// escape), and the three answers are the documented ones.
    @Test func theRouteChecksTheTokenAndAnswersAsDocumented() async throws {
        let suite = "test.remote.stop.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let token = RemoteAccessToken(defaults: defaults)
        let fake = FakeTerminalService()
        let store = await storeWithOneTerminal(fake, defaults: defaults)
        let refId = store.projects[0].terminals[0].id
        let server = RemoteServer(store: store, streamer: LocalFakeStreamer(), token: token,
                                  host: "127.0.0.1", port: 0)
        await server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(10)
        while server.boundPort == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let port = try #require(server.boundPort)

        func post(_ sid: String, token: String) async throws -> (status: Int, body: Data) {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/sessions/\(sid)/stop?token=\(token)"))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }

        let refused = try await post("%12", token: "not-the-token")
        #expect(refused.status == 401)
        #expect(fake.stopCalls.isEmpty)

        let unknown = try await post("%13", token: token.value)
        #expect(unknown.status == 404)
        #expect(unknown.body.isEmpty)
        #expect(fake.stopCalls.isEmpty)

        let stopped = try await post("%12", token: token.value)
        #expect(stopped.status == 200)
        #expect(fake.stopCalls == ["%12"])
        let object = try #require(try JSONSerialization.jsonObject(with: stopped.body) as? [String: Any])
        #expect(object["id"] as? String == refId.uuidString)
        #expect(object["session_id"] as? String == "%12")
        #expect(store.projects[0].terminals.count == 1)
    }
}
