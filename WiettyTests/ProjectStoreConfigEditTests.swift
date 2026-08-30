import Testing
import Foundation
@testable import Wietty

/// The Edit workspace page writes `wietty.json` through the store's config-editing
/// mutators. These pin what each one writes to the file, that an in-app edit never
/// re-raises the approval prompt (typing it here is the consent), and that a
/// hand-written definition keeps its minimal shape when a neighbour is edited.
@Suite @MainActor struct ProjectStoreConfigEditTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("workspace")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A store with one workspace whose `wietty.json` is `config`, already read and
    /// approved so the edit mutators start from a clean, synced state.
    private func makeStore(config: WorkspaceConfig = WorkspaceConfig(name: nil, agents: [], terminals: []))
        throws -> (ProjectStore, UUID, URL) {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder()
        _ = try ConfigFile.write(config, in: folder)
        store.addProject(url: folder)
        store.approvePendingConfig()
        let id = try #require(store.projects.first).id
        store.reconcileWithFile(id)
        return (store, id, folder)
    }

    // MARK: shell_init

    @Test func setShellInitWritesLinesAndDropsBlanks() throws {
        let (store, id, folder) = try makeStore()
        store.setShellInit(["export PATH=$HOME/bin:$PATH", "  ", "source ~/env.sh"], for: id)
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.shellInit == ["export PATH=$HOME/bin:$PATH", "source ~/env.sh"])
        #expect(store.pendingConfigApproval == nil)
    }

    @Test func setShellInitToEmptyRemovesTheKey() throws {
        let (store, id, folder) = try makeStore(
            config: WorkspaceConfig(name: nil, agents: [], terminals: [], shellInit: ["export X=1"])
        )
        store.setShellInit([], for: id)
        let raw = try #require(ConfigFile.rawData(in: folder))
        #expect(!String(decoding: raw, as: UTF8.self).contains("shell_init"))
    }

    // MARK: processes

    @Test func addProcessWritesDefinitionAndAutoApproves() throws {
        let (store, id, folder) = try makeStore()
        let added = store.addProcess(
            name: "web", config: ProcessConfig(command: "npm run dev", autoStart: true), for: id
        )
        #expect(added)
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.processes?["web"]?.command == "npm run dev")
        #expect(reread.processes?["web"]?.autoStart == true)
        // The command is a shell line; typing it on the page is agreeing to it.
        #expect(store.pendingConfigApproval == nil)
    }

    @Test func addProcessRefusesDuplicateAndEmptyName() throws {
        let (store, id, _) = try makeStore()
        #expect(store.addProcess(name: "web", config: ProcessConfig(command: "a"), for: id))
        #expect(!store.addProcess(name: "web", config: ProcessConfig(command: "b"), for: id))
        #expect(!store.addProcess(name: "  ", config: ProcessConfig(command: "c"), for: id))
        #expect(store.projects.first?.configProcesses?["web"]?.command == "a")
    }

    @Test func updateProcessRenamesAndRefusesCollision() throws {
        let (store, id, folder) = try makeStore()
        _ = store.addProcess(name: "web", config: ProcessConfig(command: "npm run dev"), for: id)
        _ = store.addProcess(name: "api", config: ProcessConfig(command: "go run ."), for: id)
        // Rename web -> server, editing its command in the same move.
        #expect(store.updateProcess(originalName: "web", name: "server",
                                    config: ProcessConfig(command: "npm start"), for: id))
        // Renaming onto an existing name is refused.
        #expect(!store.updateProcess(originalName: "api", name: "server",
                                     config: ProcessConfig(command: "go run ."), for: id))
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.processes?["web"] == nil)
        #expect(reread.processes?["server"]?.command == "npm start")
        #expect(reread.processes?["api"]?.command == "go run .")
    }

    @Test func removeProcessClearsSectionWhenEmpty() throws {
        let (store, id, folder) = try makeStore()
        _ = store.addProcess(name: "web", config: ProcessConfig(command: "npm run dev"), for: id)
        store.removeProcess(name: "web", for: id)
        let raw = try #require(ConfigFile.rawData(in: folder))
        #expect(!String(decoding: raw, as: UTF8.self).contains("processes"))
    }

    /// A hand-written process that sets only `command` must not gain `auto_start`,
    /// `env` and the rest as noise when a different process is edited.
    @Test func editingOneProcessKeepsAnotherMinimal() throws {
        let (store, id, folder) = try makeStore(config: WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            processes: ["lean": ProcessConfig(command: "make")]
        ))
        _ = store.addProcess(name: "extra", config: ProcessConfig(command: "make test"), for: id)
        let raw = String(decoding: try #require(ConfigFile.rawData(in: folder)), as: UTF8.self)
        #expect(!raw.contains("auto_start"))
        #expect(!raw.contains("\"env\""))
    }

    // MARK: tests

    @Test func addTestWritesDefinition() throws {
        let (store, id, folder) = try makeStore()
        #expect(store.addTest(name: "phpstan", config: TestConfig(command: "phpstan analyse"), for: id))
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.tests?["phpstan"]?.command == "phpstan analyse")
        #expect(store.pendingConfigApproval == nil)
    }

    @Test func updateAndRemoveTest() throws {
        let (store, id, folder) = try makeStore()
        _ = store.addTest(name: "unit", config: TestConfig(command: "phpunit"), for: id)
        #expect(store.updateTest(originalName: "unit", name: "phpunit",
                                 config: TestConfig(command: "php artisan test"), for: id))
        store.removeTest(name: "phpunit", for: id)
        let raw = String(decoding: try #require(ConfigFile.rawData(in: folder)), as: UTF8.self)
        #expect(!raw.contains("tests"))
    }

    // MARK: agents and terminals

    @Test func addAgentRowWritesAgentEntry() throws {
        let (store, id, folder) = try makeStore()
        #expect(store.addAgentRow(slot: "Opus", type: "claude --model claude-opus-5",
                                  prefix: "[default]", for: id))
        let reread = try #require(try ConfigFile.read(in: folder))
        let agent = try #require(reread.agents.first)
        #expect(agent.slot == "Opus")
        #expect(agent.type == "claude --model claude-opus-5")
        #expect(agent.prefix == "[default]")
        #expect(store.pendingConfigApproval == nil)
    }

    @Test func addAgentRowRefusesDuplicateSlot() throws {
        let (store, id, _) = try makeStore()
        #expect(store.addAgentRow(slot: "Claude 1", type: "claude", for: id))
        #expect(!store.addAgentRow(slot: "Claude 1", type: "claude", for: id))
    }

    @Test func addTerminalRowWritesLabel() throws {
        let (store, id, folder) = try makeStore()
        #expect(store.addTerminalRow(slot: "server logs", for: id))
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.terminals == ["server logs"])
    }

    @Test func updateConfigRowEditsIdleAgentType() throws {
        let (store, id, folder) = try makeStore()
        _ = store.addAgentRow(slot: "a", type: "claude", for: id)
        let refId = try #require(store.projects.first?.terminals.first).id
        #expect(store.updateConfigRow(refId, slot: "a", type: "codex --model o3",
                                      prefix: "", fixedNaming: true, for: id))
        let reread = try #require(try ConfigFile.read(in: folder))
        let agent = try #require(reread.agents.first)
        #expect(agent.type == "codex --model o3")
        #expect(agent.fixedNaming)
    }

    /// A running agent row keeps the line it was started with; only slot and the
    /// display fields change. Matches `ConfigReconcile.apply`'s running-row rule.
    @Test func updateConfigRowLeavesRunningAgentLineAlone() async throws {
        let (store, id, folder) = try makeStore()
        let project = try #require(store.projects.first)
        // A live agent row: opened with the default `claude` line (command nil).
        let ref = try await store.openSessionThrowing(for: project, kind: .claude)
        #expect(store.updateConfigRow(ref.id, slot: "renamed", type: "codex",
                                      prefix: "[x]", fixedNaming: false, for: id))
        let reread = try #require(try ConfigFile.read(in: folder))
        let agent = try #require(reread.agents.first)
        #expect(agent.slot == "renamed")
        #expect(agent.prefix == "[x]")
        // The type stayed `claude` (written as the default): the session runs it.
        #expect(agent.type == "claude")
    }

    @Test func updateConfigRowRefusesSlotCollision() throws {
        let (store, id, _) = try makeStore()
        _ = store.addAgentRow(slot: "a", type: "claude", for: id)
        _ = store.addAgentRow(slot: "b", type: "claude", for: id)
        let bId = try #require(store.projects.first?.terminals.first { $0.slot == "b" }).id
        #expect(!store.updateConfigRow(bId, slot: "a", type: "claude",
                                       prefix: "", fixedNaming: false, for: id))
    }

    @Test func moveConfigRowsReordersWithinKind() throws {
        let (store, id, folder) = try makeStore()
        _ = store.addTerminalRow(slot: "first", for: id)
        _ = store.addTerminalRow(slot: "second", for: id)
        _ = store.addTerminalRow(slot: "third", for: id)
        // Move "third" (index 2) to the front.
        store.moveConfigRows(kind: .terminal, fromOffsets: IndexSet(integer: 2), toOffset: 0, for: id)
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.terminals == ["third", "first", "second"])
    }

    /// Reordering one kind leaves the other kind's rows and order alone.
    @Test func moveConfigRowsLeavesTheOtherKindAlone() throws {
        let (store, id, folder) = try makeStore()
        _ = store.addAgentRow(slot: "agentA", type: "claude", for: id)
        _ = store.addTerminalRow(slot: "t1", for: id)
        _ = store.addTerminalRow(slot: "t2", for: id)
        store.moveConfigRows(kind: .terminal, fromOffsets: IndexSet(integer: 1), toOffset: 0, for: id)
        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.agents.map(\.slot) == ["agentA"])
        #expect(reread.terminals == ["t2", "t1"])
    }
}
