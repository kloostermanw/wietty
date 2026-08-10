import Testing
import Foundation
@testable import Wietty

@Suite @MainActor struct MCPToolRouterTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a store + router with `count` empty workspaces, returning both
    /// plus the fake service so tests can assert on forwarded calls.
    private func makeRouter(
        projectNames: [String] = []
    ) -> (router: MCPToolRouter, store: ProjectStore, fake: FakeTerminalService) {
        let fake = FakeTerminalService()
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        for name in projectNames { store.addProject(url: makeTempFolder(named: name)) }
        return (MCPToolRouter(store: store), store, fake)
    }

    // MARK: - Projects

    @Test func listProjectsReturnsAllWorkspaces() async throws {
        let (router, _, _) = makeRouter(projectNames: ["alpha", "beta"])
        let result = try await router.call("list_projects", arguments: [:])
        let names = result["projects"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["alpha", "beta"])
    }

    @Test func getProjectByIdReturnsDetailWithTerminals() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let result = try await router.call("get_project", arguments: ["project_id": .string(id.uuidString)])
        #expect(result["name"]?.stringValue == "alpha")
        #expect(result["terminals"]?.arrayValue?.count == 1)
    }

    @Test func getProjectUnknownIdThrows() async throws {
        let (router, _, _) = makeRouter(projectNames: ["alpha"])
        await #expect(throws: MCPToolError.self) {
            _ = try await router.call("get_project", arguments: ["project_id": .string(UUID().uuidString)])
        }
    }

    @Test func getProjectWithoutIdUsesSelectedWorkspace() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha", "beta"])
        let betaId = store.projects[1].id
        _ = try await router.call("select_project", arguments: ["project_id": .string(betaId.uuidString)])
        let result = try await router.call("get_project", arguments: [:])
        #expect(result["name"]?.stringValue == "beta")
    }

    @Test func getProjectWithoutIdOrSelectionThrowsMissingArgument() async throws {
        let (router, _, _) = makeRouter(projectNames: ["alpha"])
        await #expect(throws: MCPToolError.missingArgument("project_id")) {
            _ = try await router.call("get_project", arguments: [:])
        }
    }

    @Test func createProjectAddsExistingFolder() async throws {
        let (router, store, _) = makeRouter()
        let folder = makeTempFolder(named: "gamma")
        let result = try await router.call("create_project", arguments: ["path": .string(folder.path)])
        #expect(result["name"]?.stringValue == "gamma")
        #expect(store.projects.map(\.name) == ["gamma"])
    }

    @Test func createProjectWithMissingFolderThrows() async throws {
        let (router, _, _) = makeRouter()
        await #expect(throws: MCPToolError.self) {
            _ = try await router.call("create_project", arguments: ["path": .string("/no/such/folder/wietty-xyz")])
        }
    }

    @Test func deleteProjectRemovesWorkspace() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha", "beta"])
        let id = store.projects[0].id
        let result = try await router.call("delete_project", arguments: ["project_id": .string(id.uuidString)])
        #expect(result["deleted"]?.boolValue == true)
        #expect(store.projects.map(\.name) == ["beta"])
    }

    @Test func selectProjectSetsDefaultForLaterCalls() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("select_project", arguments: ["project_id": .string(id.uuidString)])
        #expect(router.selectedProjectId == id)
    }

    // MARK: - Sessions

    @Test func spawnProcessAppendsTerminalSession() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        let result = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        #expect(result["kind"]?.stringValue == "terminal")
        #expect(result["label"]?.stringValue == "Terminal 1")
        #expect(store.projects[0].terminals.count == 1)
        #expect(store.projects[0].terminals[0].kind == .terminal)
    }

    @Test func spawnProcessWithClaudeKindRunsClaude() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        let result = try await router.call(
            "spawn_process", arguments: ["project_id": .string(id.uuidString), "kind": .string("claude")]
        )
        #expect(result["kind"]?.stringValue == "claude")
        #expect(result["label"]?.stringValue == "Claude 1")
        // A shell with `claude` typed into it, the same as a row opened by hand.
        #expect(fake.openCalls.last?.command == nil)
        #expect(fake.sendCalls.last?.text == "claude\n")
    }

    @Test func spawnAgentIsClaudeShorthand() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        let result = try await router.call("spawn_agent", arguments: ["project_id": .string(id.uuidString)])
        #expect(result["kind"]?.stringValue == "claude")
        #expect(fake.openCalls.last?.command == nil)
        #expect(fake.sendCalls.last?.text == "claude\n")
    }

    @Test func spawnProcessRejectsInvalidKind() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        await #expect(throws: MCPToolError.self) {
            _ = try await router.call(
                "spawn_process", arguments: ["project_id": .string(id.uuidString), "kind": .string("banana")]
            )
        }
    }

    @Test func sendInputForwardsTextToService() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        let result = try await router.call(
            "send_input", arguments: ["session_id": .string(sid), "text": .string("ls\n")]
        )
        #expect(result["sent"]?.boolValue == true)
        #expect(fake.sendCalls.last?.sessionId == sid)
        #expect(fake.sendCalls.last?.text == "ls\n")
    }

    @Test func sendInputUnknownSessionThrows() async throws {
        let (router, _, _) = makeRouter(projectNames: ["alpha"])
        await #expect(throws: MCPToolError.unknownSession("nope")) {
            _ = try await router.call("send_input", arguments: ["session_id": .string("nope"), "text": .string("x")])
        }
    }

    @Test func sendInputMissingTextThrows() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        await #expect(throws: MCPToolError.missingArgument("text")) {
            _ = try await router.call("send_input", arguments: ["session_id": .string(sid)])
        }
    }

    @Test func closeProcessClosesAndDropsSession() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        let result = try await router.call("close_process", arguments: ["session_id": .string(sid)])
        #expect(result["closed"]?.boolValue == true)
        #expect(fake.closeCalls.contains(sid))
        #expect(store.projects[0].terminals.isEmpty)
    }

    @Test func selectProcessReturnsFocusResult() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        fake.focusResult = FocusResult(found: true, jobName: "claude")
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        let result = try await router.call("select_process", arguments: ["session_id": .string(sid)])
        #expect(result["found"]?.boolValue == true)
        #expect(result["job_name"]?.stringValue == "claude")
    }

    @Test func renameProcessUpdatesLabel() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        let result = try await router.call(
            "rename_process", arguments: ["session_id": .string(sid), "name": .string("build")]
        )
        #expect(result["label"]?.stringValue == "build")
        #expect(store.projects[0].terminals[0].label == "build")
    }

    @Test func getProcessOutputReturnsContentsAndClampsLines() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        fake.readOutputResult = "line one\nline two"
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        let result = try await router.call(
            "get_process_output", arguments: ["session_id": .string(sid), "lines": .int(9999)]
        )
        #expect(result["output"]?.stringValue == "line one\nline two")
        #expect(fake.readOutputCalls.last?.maxLines == 200)
    }

    @Test func restartProcessReopensSessionKeepingRefIdentity() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let originalRefId = store.projects[0].terminals[0].id
        let originalSession = store.projects[0].terminals[0].sessionId
        let result = try await router.call("restart_process", arguments: ["session_id": .string(originalSession)])
        #expect(result["id"]?.stringValue == originalRefId.uuidString)
        #expect(result["session_id"]?.stringValue != originalSession)
        #expect(store.projects[0].terminals.count == 1)
    }

    // MARK: - Listing / status

    @Test func listProcessesSpansAllWorkspaces() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha", "beta"])
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(store.projects[0].id.uuidString)])
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(store.projects[1].id.uuidString)])
        let result = try await router.call("list_processes", arguments: [:])
        #expect(result["processes"]?.arrayValue?.count == 2)
    }

    @Test func listProcessesScopedToWorkspace() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha", "beta"])
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(store.projects[0].id.uuidString)])
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(store.projects[1].id.uuidString)])
        let result = try await router.call(
            "list_processes", arguments: ["project_id": .string(store.projects[0].id.uuidString)]
        )
        #expect(result["processes"]?.arrayValue?.count == 1)
    }

    @Test func getProcessStatusReportsRunState() async throws {
        let (router, store, _) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        let result = try await router.call("get_process_status", arguments: ["session_id": .string(sid)])
        #expect(result["run_state"]?.stringValue == "running")
        #expect(result["needs_attention"]?.boolValue == false)
    }

    @Test func unknownToolThrows() async throws {
        let (router, _, _) = makeRouter()
        await #expect(throws: MCPToolError.unknownTool("frobnicate")) {
            _ = try await router.call("frobnicate", arguments: [:])
        }
    }
}
