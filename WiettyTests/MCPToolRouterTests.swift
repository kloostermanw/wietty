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
        // The trailing newline is rewritten to a carriage return, which is what the
        // Return key sends and what a raw mode reader (Claude Code) treats as submit.
        #expect(fake.sendCalls.last?.text == "ls\r")
    }

    @Test func sendInputRewritesNewlinesToCarriageReturns() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        // Bare LF, CRLF, and an embedded newline all become a single CR each, so
        // every line is submitted the way a keyboard would submit it.
        _ = try await router.call(
            "send_input", arguments: ["session_id": .string(sid), "text": .string("a\nb\r\nc\n")]
        )
        #expect(fake.sendCalls.last?.text == "a\rb\rc\r")
    }

    @Test func sendInputLeavesTextWithoutNewlinesUnchanged() async throws {
        let (router, store, fake) = makeRouter(projectNames: ["alpha"])
        let id = store.projects[0].id
        _ = try await router.call("spawn_process", arguments: ["project_id": .string(id.uuidString)])
        let sid = store.projects[0].terminals[0].sessionId
        // Text meant to land in the input box without submitting stays verbatim.
        _ = try await router.call(
            "send_input", arguments: ["session_id": .string(sid), "text": .string("partial")]
        )
        #expect(fake.sendCalls.last?.text == "partial")
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

    // MARK: - Managed processes and tests

    /// Builds a store whose supervisors use fake launchers (so nothing is spawned),
    /// with one workspace carrying the given process and test definitions already
    /// applied. Returns the router, the workspace, and the two fake launchers so a
    /// test can drive output into a running process.
    private func makeManagedRouter(
        processes: [String: ProcessConfig] = [:],
        tests: [String: TestConfig] = [:]
    ) -> (router: MCPToolRouter, store: ProjectStore, project: Project, procLauncher: FakeProcessLauncher, testLauncher: FakeProcessLauncher) {
        let procLauncher = FakeProcessLauncher()
        let testLauncher = FakeProcessLauncher()
        let store = ProjectStore(
            defaults: makeDefaults(), service: FakeTerminalService(),
            processSupervisor: ProcessSupervisor(launcher: procLauncher),
            testSupervisor: TestSupervisor(launcher: testLauncher)
        )
        store.addProject(url: makeTempFolder(named: "alpha"))
        let project = store.projects[0]
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [],
                                     processes: processes, tests: tests)
        store.processes.apply(config, projectId: project.id, directory: project.url)
        store.testSupervisor.apply(config, projectId: project.id, directory: project.url)
        return (MCPToolRouter(store: store), store, project, procLauncher, testLauncher)
    }

    @Test func listManagedProcessesReturnsBothProcessesAndTests() async throws {
        let (router, _, _, _, _) = makeManagedRouter(
            processes: ["queue": ProcessConfig(command: "run-queue")],
            tests: ["phpunit": TestConfig(command: "phpunit")]
        )
        let result = try await router.call("list_managed_processes", arguments: [:])
        let items = result["managed_processes"]?.arrayValue ?? []
        #expect(items.count == 2)
        let byType = Dictionary(grouping: items) { $0["type"]?.stringValue ?? "" }
        #expect(byType["process"]?.first?["name"]?.stringValue == "queue")
        #expect(byType["test"]?.first?["name"]?.stringValue == "phpunit")
    }

    /// The listed id round-trips through `ManagedProcessID`, so what an agent copies
    /// out of the list is the same handle the read tools resolve.
    @Test func listManagedProcessesEmitsResolvableIds() async throws {
        let (router, _, project, _, _) = makeManagedRouter(
            processes: ["queue": ProcessConfig(command: "run-queue")]
        )
        let result = try await router.call("list_managed_processes", arguments: [:])
        let id = result["managed_processes"]?.arrayValue?.first?["id"]?.stringValue
        #expect(ManagedProcessID.parse(id ?? "")
            == ManagedProcessID.Parsed(projectId: project.id, name: "queue", isTest: false))
    }

    @Test func listManagedProcessesScopesToOneWorkspace() async throws {
        // A second workspace with its own process must not show up when scoped.
        let procLauncher = FakeProcessLauncher()
        let store = ProjectStore(
            defaults: makeDefaults(), service: FakeTerminalService(),
            processSupervisor: ProcessSupervisor(launcher: procLauncher),
            testSupervisor: TestSupervisor(launcher: FakeProcessLauncher())
        )
        store.addProject(url: makeTempFolder(named: "alpha"))
        store.addProject(url: makeTempFolder(named: "beta"))
        for project in store.projects {
            let config = WorkspaceConfig(name: nil, agents: [], terminals: [],
                                         processes: ["queue": ProcessConfig(command: "run-queue")])
            store.processes.apply(config, projectId: project.id, directory: project.url)
        }
        let router = MCPToolRouter(store: store)
        let scoped = try await router.call(
            "list_managed_processes", arguments: ["project_id": .string(store.projects[0].id.uuidString)]
        )
        #expect(scoped["managed_processes"]?.arrayValue?.count == 1)
        let all = try await router.call("list_managed_processes", arguments: [:])
        #expect(all["managed_processes"]?.arrayValue?.count == 2)
    }

    @Test func getManagedProcessOutputReturnsRecentLines() async throws {
        let (router, store, project, procLauncher, _) = makeManagedRouter(
            processes: ["queue": ProcessConfig(command: "run-queue")]
        )
        let process = try #require(store.processes.process(projectId: project.id, name: "queue"))
        process.start()
        procLauncher.last.onOutput("line 1\nline 2\n")
        let id = ManagedProcessID.string(projectId: project.id, name: "queue", isTest: false)
        let result = try await router.call("get_managed_process_output", arguments: ["id": .string(id)])
        #expect(result["id"]?.stringValue == id)
        #expect(result["output"]?.stringValue == "line 1\nline 2")
    }

    @Test func getManagedProcessOutputHonorsLineCount() async throws {
        let (router, store, project, procLauncher, _) = makeManagedRouter(
            processes: ["queue": ProcessConfig(command: "run-queue")]
        )
        let process = try #require(store.processes.process(projectId: project.id, name: "queue"))
        process.start()
        procLauncher.last.onOutput("a\nb\nc\n")
        let id = ManagedProcessID.string(projectId: project.id, name: "queue", isTest: false)
        let result = try await router.call(
            "get_managed_process_output", arguments: ["id": .string(id), "lines": .int(2)]
        )
        #expect(result["output"]?.stringValue == "b\nc")
    }

    /// A process and a test may share a name; the handle's kind keeps their output
    /// separate rather than resolving to whichever the supervisor found first.
    @Test func getManagedProcessOutputSeparatesProcessFromTestOfTheSameName() async throws {
        let (router, store, project, procLauncher, testLauncher) = makeManagedRouter(
            processes: ["build": ProcessConfig(command: "build-proc")],
            tests: ["build": TestConfig(command: "build-test")]
        )
        let process = try #require(store.processes.process(projectId: project.id, name: "build"))
        process.start()
        procLauncher.last.onOutput("from process\n")
        store.testSupervisor.run(projectId: project.id, name: "build")
        testLauncher.last.onOutput("from test\n")

        let processId = ManagedProcessID.string(projectId: project.id, name: "build", isTest: false)
        let testId = ManagedProcessID.string(projectId: project.id, name: "build", isTest: true)
        let processOut = try await router.call("get_managed_process_output", arguments: ["id": .string(processId)])
        let testOut = try await router.call("get_managed_process_output", arguments: ["id": .string(testId)])
        #expect(processOut["output"]?.stringValue == "from process")
        #expect(testOut["output"]?.stringValue == "from test")
    }

    @Test func getManagedProcessStatusReportsAnIdleProcess() async throws {
        let (router, _, project, _, _) = makeManagedRouter(
            processes: ["queue": ProcessConfig(command: "run-queue")]
        )
        let id = ManagedProcessID.string(projectId: project.id, name: "queue", isTest: false)
        let result = try await router.call("get_managed_process_status", arguments: ["id": .string(id)])
        #expect(result["status"]?.stringValue == "idle")
        #expect(result["running"]?.boolValue == false)
        #expect(result["type"]?.stringValue == "process")
    }

    @Test func getManagedProcessOutputForUnknownProcessThrows() async throws {
        let (router, _, project, _, _) = makeManagedRouter()
        let id = ManagedProcessID.string(projectId: project.id, name: "ghost", isTest: false)
        await #expect(throws: MCPToolError.unknownManagedProcess(id)) {
            _ = try await router.call("get_managed_process_output", arguments: ["id": .string(id)])
        }
    }

    @Test func getManagedProcessOutputForMalformedIdThrows() async throws {
        let (router, _, _, _, _) = makeManagedRouter()
        await #expect {
            _ = try await router.call("get_managed_process_output", arguments: ["id": .string("garbage")])
        } throws: { error in
            guard case MCPToolError.invalidArgument = error else { return false }
            return true
        }
    }
}
