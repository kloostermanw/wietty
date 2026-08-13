import Testing
import Foundation
@testable import Wietty

/// Starting a row for an agent from the list, which is the same shell every other
/// row is with a different line typed into it.
///
/// The line is stored on the row rather than derived from its kind, and these tests
/// are why: a row only knows what to type once, when it is opened, and everything
/// after that (clicking a dead row, restarting one, an agent that exited back to a
/// prompt) has to type the same thing again. Derived from the kind, all three typed
/// `claude` into a Codex row.
@Suite @MainActor struct AgentLaunchTests {
    private let codex = AgentDefinition(name: "Codex", command: "codex",
                                        defaultArguments: "--model o3")

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("proj")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ fake: FakeTerminalService) -> ProjectStore {
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder())
        return store
    }

    @Test func openingAnAgentTypesItsCommandWithTheDefaultArguments() async {
        let fake = FakeTerminalService()
        let store = store(fake)

        await store.openAgent(codex, for: store.projects[0])

        #expect(store.projects[0].terminals.map(\.label) == ["Codex 1"])
        #expect(store.projects[0].terminals[0].kind == .claude)
        // A plain shell with the line typed into it, the same as a Claude row.
        #expect(fake.openCalls[0].command == nil)
        #expect(fake.sendCalls.map(\.text) == ["codex --model o3\n"])
    }

    @Test func typedArgumentsReplaceTheDefaults() async {
        let fake = FakeTerminalService()
        let store = store(fake)

        await store.openAgent(codex, arguments: "--resume", for: store.projects[0])

        #expect(fake.sendCalls.map(\.text) == ["codex --resume\n"])
    }

    /// The row remembers its line, so nothing later has to ask the agent list about
    /// it. An agent renamed or deleted after its row was opened must not change what
    /// that row restarts as.
    @Test func theRowRemembersTheLineItWasOpenedWith() async {
        let fake = FakeTerminalService()
        let store = store(fake)

        await store.openAgent(codex, for: store.projects[0])
        store.removeAgent(id: codex.id)

        #expect(store.projects[0].terminals[0].command == "codex --model o3")
    }

    /// Clicking a row whose terminal died reopens it, and the reopen has to type the
    /// row's own line. This is the path that typed `claude` into a Codex row.
    @Test func reopeningADeadRowTypesItsOwnLine() async {
        let fake = FakeTerminalService()
        let store = store(fake)
        await store.openAgent(codex, for: store.projects[0])
        fake.sendCalls.removeAll()
        fake.focusResult = FocusResult(found: false, jobName: nil)

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])

        #expect(fake.sendCalls.map(\.text) == ["codex --model o3\n"])
    }

    /// The same for a live terminal whose agent exited back to a prompt: the row is
    /// clicked, the foreground job is a shell, and the agent is started again.
    @Test func restartingAStoppedAgentTypesItsOwnLine() async {
        let fake = FakeTerminalService()
        let store = store(fake)
        await store.openAgent(codex, for: store.projects[0])
        fake.sendCalls.removeAll()
        fake.focusResult = FocusResult(found: true, jobName: "zsh")

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])

        #expect(fake.sendCalls.map(\.text) == ["codex --model o3\n"])
    }

    /// And the third path that re-runs a row: the restart button on the row itself,
    /// which closes the session and opens a fresh one.
    @Test func restartingARowTypesItsOwnLine() async {
        let fake = FakeTerminalService()
        let store = store(fake)
        await store.openAgent(codex, for: store.projects[0])
        fake.sendCalls.removeAll()

        await store.restartTerminal(sessionId: store.projects[0].terminals[0].sessionId)

        #expect(fake.sendCalls.map(\.text) == ["codex --model o3\n"])
    }

    /// Every row stored before this list existed, and every row imported from a
    /// `wietty.json`, carries no line of its own. Those are Claude rows, and they
    /// keep behaving as such.
    @Test func aRowWithNoLineOfItsOwnStillRunsClaude() async {
        let fake = FakeTerminalService()
        let store = store(fake)
        await store.openClaude(for: store.projects[0])
        #expect(store.projects[0].terminals[0].command == nil)
        fake.sendCalls.removeAll()
        fake.focusResult = FocusResult(found: true, jobName: "zsh")

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])

        #expect(fake.sendCalls.map(\.text) == ["claude\n"])
    }

    /// Agent rows share the Claude counter, so two agents in one workspace are
    /// numbered 1 and 2 rather than both 1.
    @Test func agentRowsShareTheAgentNumbering() async {
        let fake = FakeTerminalService()
        let store = store(fake)

        await store.openClaude(for: store.projects[0])
        await store.openAgent(codex, for: store.projects[0])

        #expect(store.projects[0].terminals.map(\.label) == ["Claude 1", "Codex 2"])
    }
}
