import Testing
import Foundation
import MCP
@testable import Wietty

/// Drives the MCP server through `StatelessHTTPServerTransport.handleRequest`,
/// the same entry point `MCPServerHost`'s HTTP route calls. No port is bound and
/// no Hummingbird application is started, but the server and transport come from
/// the production factories so the wiring under test is the real one.
@Suite @MainActor struct MCPServerHostTests {
    private func makeRouter(projectNames: [String] = []) -> MCPToolRouter {
        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 service: FakeTerminalService())
        for name in projectNames {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let url = base.appendingPathComponent(name)
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            store.addProject(url: url)
        }
        return MCPToolRouter(store: store)
    }

    private func makeStartedTransport(router: MCPToolRouter) async throws -> StatelessHTTPServerTransport {
        let transport = MCPServerHost.makeTransport()
        _ = try await MCPServerHost.makeStartedServer(router: router, transport: transport)
        return transport
    }

    private func post(_ body: [String: Any], to transport: StatelessHTTPServerTransport) async throws -> [String: Any] {
        let request = MCP.HTTPRequest(
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            path: "/mcp"
        )
        let response = await transport.handleRequest(request)
        let data = try #require(response.bodyData)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func initializeBody(id: Int, protocolVersion: String = "2025-06-18",
                                clientName: String = "probe") -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": clientName, "version": "1"],
            ],
        ]
    }

    // MARK: - Handshake

    @Test func initializeSucceeds() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let response = try await post(initializeBody(id: 1), to: transport)

        #expect(response["error"] == nil)
        #expect((response["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    }

    /// Regression test for #37: every client after the first must be able to
    /// handshake. The SDK's default handler latches after the first `initialize`
    /// and answers every later one with `-32600 Invalid Request: Server is
    /// already initialized`.
    ///
    /// If this fails, suspect `MCPServerHost.makeStartedServer`: its `initialize`
    /// override must be registered *after* `Server.start`, or `start`'s own
    /// `registerDefaultHandlers` silently replaces it with the latching default.
    @Test func initializeTwiceBothSucceed() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let first = try await post(initializeBody(id: 1, clientName: "first"), to: transport)
        let second = try await post(initializeBody(id: 2, clientName: "second"), to: transport)
        let third = try await post(initializeBody(id: 3, clientName: "third"), to: transport)

        // Asserted on the error rather than just `result` so a regression names
        // the SDK's latch instead of only reporting a missing field.
        for (label, response) in [("first", first), ("second", second), ("third", third)] {
            let message = (response["error"] as? [String: Any])?["message"] as? String
            #expect(message == nil, "\(label) handshake was rejected: \(message ?? "")")
        }
        #expect((second["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        #expect((third["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    }

    /// The override never calls the SDK's `setInitialState`, so `isInitialized`
    /// stays false forever. That is safe only while the server is built with a
    /// non-strict `Server.Configuration`, which is what pins this test: under
    /// `.strict` the SDK rejects every non-initialize request from a client it
    /// considers uninitialized.
    @Test func toolsWorkWithoutAnyHandshake() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let list = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:],
        ], to: transport)

        #expect(list["error"] == nil)
        #expect((list["result"] as? [String: Any])?["tools"] as? [[String: Any]] != nil)
    }

    @Test func initializeReportsWiettyAsTheServer() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let response = try await post(initializeBody(id: 1), to: transport)

        let info = (response["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(info?["name"] as? String == "wietty")
        #expect(info?["version"] as? String == "1.0")
    }

    @Test func initializeEchoesASupportedProtocolVersion() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let response = try await post(initializeBody(id: 1, protocolVersion: "2024-11-05"), to: transport)

        #expect((response["result"] as? [String: Any])?["protocolVersion"] as? String == "2024-11-05")
    }

    @Test func initializeFallsBackToLatestForAnUnsupportedProtocolVersion() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let response = try await post(initializeBody(id: 1, protocolVersion: "1999-01-01"), to: transport)

        #expect((response["result"] as? [String: Any])?["protocolVersion"] as? String == Version.latest)
    }

    // MARK: - Tools

    @Test func toolsKeepWorkingAfterRepeatedHandshakes() async throws {
        let transport = try await makeStartedTransport(router: makeRouter(projectNames: ["alpha"]))
        let first = try await post(initializeBody(id: 1, clientName: "first"), to: transport)
        let second = try await post(initializeBody(id: 2, clientName: "second"), to: transport)

        let list = try await post([
            "jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [:],
        ], to: transport)
        let call = try await post([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "list_projects", "arguments": [:]],
        ], to: transport)

        // Both handshakes are asserted, not discarded: without this the test
        // passes against the pre-#37 code, because `tools/*` does not depend on
        // handshake state and a rejected second `initialize` goes unnoticed.
        #expect(first["error"] == nil)
        #expect(second["error"] == nil)
        let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.contains { $0["name"] as? String == "list_projects" } == true)
        let content = (call["result"] as? [String: Any])?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String
        #expect(text?.contains("alpha") == true, "list_projects payload: \(text ?? "nil")")
        #expect(((call["result"] as? [String: Any])?["isError"] as? Bool) == false)
    }

    @Test func callingAnUnknownToolReportsAToolLevelError() async throws {
        let transport = try await makeStartedTransport(router: makeRouter())

        let call = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "no_such_tool", "arguments": [:]],
        ], to: transport)

        // The adapter converts a thrown router error into a tool-level error
        // result, not a JSON-RPC error, so clients see it as a failed tool call.
        #expect(call["error"] == nil)
        let result = try #require(call["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.isEmpty == false)
    }
}
