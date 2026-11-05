import Testing
import Foundation
@testable import Wietty

/// The two status bar items beside the MCP one: how many terminals, agents, managed
/// processes and tests are running, and how much memory the app uses.
@MainActor
@Suite struct RunningProcessCountTests {
    private func makeStore() -> (ProjectStore, FakeProcessLauncher, FakeProcessLauncher) {
        let procLauncher = FakeProcessLauncher()
        let testLauncher = FakeProcessLauncher()
        let store = ProjectStore(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
            service: FakeTerminalService(),
            processSupervisor: ProcessSupervisor(launcher: procLauncher),
            testSupervisor: TestSupervisor(launcher: testLauncher)
        )
        return (store, procLauncher, testLauncher)
    }

    private func addWorkspace(to store: ProjectStore, processes: [String: ProcessConfig],
                              tests: [String: TestConfig] = [:]) -> Project {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("ws")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.addProject(url: url)
        let project = store.projects.last!
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [],
                                     processes: processes, tests: tests)
        store.processes.apply(config, projectId: project.id, directory: project.url)
        store.testSupervisor.apply(config, projectId: project.id, directory: project.url)
        return project
    }

    @Test func nothingDefinedCountsZero() {
        let (store, _, _) = makeStore()
        #expect(store.runningProcessCounts == RunningProcessCounts(terminals: 0, agents: 0, processes: 0, tests: 0))
    }

    /// Defined is not running: only a started process counts, and it is counted
    /// across every workspace rather than the selected one.
    @Test func countsOnlyRunningProcessesAcrossWorkspaces() throws {
        let (store, _, _) = makeStore()
        let alpha = addWorkspace(to: store, processes: ["queue": ProcessConfig(command: "q"),
                                                        "web": ProcessConfig(command: "w")])
        let beta = addWorkspace(to: store, processes: ["queue": ProcessConfig(command: "q")])

        _ = try #require(store.processes.process(projectId: alpha.id, name: "queue")).start()
        _ = try #require(store.processes.process(projectId: beta.id, name: "queue")).start()

        #expect(store.runningProcessCounts == RunningProcessCounts(terminals: 0, agents: 0, processes: 2, tests: 0))
    }

    @Test func aRunningTestCountsAsATest() throws {
        let (store, _, _) = makeStore()
        let alpha = addWorkspace(to: store, processes: [:], tests: ["unit": TestConfig(command: "t")])

        _ = try #require(store.testSupervisor.test(projectId: alpha.id, name: "unit")).start()

        #expect(store.runningProcessCounts == RunningProcessCounts(terminals: 0, agents: 0, processes: 0, tests: 1))
    }

    @Test func anExitedProcessStopsCounting() throws {
        let (store, procLauncher, _) = makeStore()
        let alpha = addWorkspace(to: store, processes: ["queue": ProcessConfig(command: "q")])
        _ = try #require(store.processes.process(projectId: alpha.id, name: "queue")).start()

        procLauncher.last.onExit(0)

        #expect(store.runningProcessCounts.total == 0)
    }

    /// Terminals and agents count by `isSessionRunning`, the rule the sidebar tints a
    /// row green by: a terminal while its shell lives, an agent only while the agent
    /// itself is the foreground job, not once it quit back to its shell.
    @Test func countsRunningTerminalsAndAgentsByTheSidebarsRule() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-T", windowId: "w1"),
                        TerminalHandle(sessionId: "sess-A", windowId: "w2"),
                        TerminalHandle(sessionId: "sess-B", windowId: "w3")]
        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 service: fake)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("ws")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.addProject(url: url)
        await store.openTerminal(for: store.projects[0])
        await store.openClaude(for: store.projects[0])
        await store.openClaude(for: store.projects[0])

        #expect(store.runningProcessCounts == RunningProcessCounts(terminals: 1, agents: 2, processes: 0, tests: 0))

        store.handle(.job(sessionId: "sess-B", jobName: "zsh")) // that agent quit to its shell
        #expect(store.runningProcessCounts == RunningProcessCounts(terminals: 1, agents: 1, processes: 0, tests: 0))

        store.handle(.job(sessionId: "sess-T", jobName: "")) // the terminal ended
        #expect(store.runningProcessCounts == RunningProcessCounts(terminals: 0, agents: 1, processes: 0, tests: 0))
    }
}

@Suite struct RunningProcessCountsPresentationTests {
    @Test func summaryCountsEveryKind() {
        #expect(RunningProcessCounts(terminals: 0, agents: 0, processes: 0, tests: 0).summary == "0 running")
        #expect(RunningProcessCounts(terminals: 2, agents: 1, processes: 2, tests: 1).summary == "6 running")
    }

    @Test func detailNamesEachKindAndPluralises() {
        #expect(RunningProcessCounts(terminals: 1, agents: 0, processes: 1, tests: 0).detail
                == "1 terminal, 0 agents, 1 process and 0 tests running")
        #expect(RunningProcessCounts(terminals: 2, agents: 1, processes: 2, tests: 1).detail
                == "2 terminals, 1 agent, 2 processes and 1 test running")
    }
}

@Suite struct AppMemoryTests {
    /// The real reading, from this very test process. Not a value, only that the
    /// call works and returns something plausible for a running process.
    @Test func theFootprintOfThisProcessIsReadable() throws {
        let bytes = try #require(AppMemory.footprintBytes())
        #expect(bytes > 1_000_000)
    }

    @Test func formatsInBinaryUnitsLikeActivityMonitor() {
        #expect(AppMemory.format(bytes: 0) == "0 MB")
        #expect(AppMemory.format(bytes: 512 * 1024 * 1024) == "512 MB")
        #expect(AppMemory.format(bytes: 1023 * 1024 * 1024 + 1024 * 1023) == "1023 MB")
        #expect(AppMemory.format(bytes: 1024 * 1024 * 1024) == "1.0 GB")
        #expect(AppMemory.format(bytes: 1536 * 1024 * 1024) == "1.5 GB")
    }
}
