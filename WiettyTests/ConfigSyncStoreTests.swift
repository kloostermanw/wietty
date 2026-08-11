import Testing
import Foundation
@testable import Wietty

@MainActor @Suite struct ConfigSyncStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func enableConfigSyncWritesCurrentRows() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        await store.openClaude(for: store.projects[0])

        #expect(store.isSyncEnabled(store.projects[0]) == false)
        store.enableConfigSync(for: store.projects[0])
        #expect(store.isSyncEnabled(store.projects[0]) == true)

        let config = try ConfigFile.read(in: folder)
        #expect(config?.agents.map(\.slot) == ["Claude 1"])
    }

    @Test func structuralChangeWritesFileWhenEnabled() async throws {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "s1", windowId: "w1"),
            TerminalHandle(sessionId: "s2", windowId: "w1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])

        await store.openTerminal(for: store.projects[0])
        var config = try ConfigFile.read(in: folder)
        #expect(config?.terminals == ["Terminal 1"])

        store.rename(store.projects[0].terminals[0], in: store.projects[0], to: "server")
        config = try ConfigFile.read(in: folder)
        #expect(config?.terminals == ["server"])
    }

    @Test func noFileMeansNoWrite() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)

        await store.openTerminal(for: store.projects[0])
        #expect(ConfigFile.exists(in: folder) == false)
    }

    @Test func addingWorkspaceWithFileScaffoldsRows() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(
                name: nil,
                agents: [.init(slot: "claude1", type: "claude")],
                terminals: ["Terminal 1"]
            ),
            in: folder
        )
        store.addProject(url: folder)
        #expect(store.projects[0].terminals.map(\.slot) == ["claude1", "Terminal 1"])
        #expect(store.projects[0].terminals[0].kind == .claude)
        #expect(store.projects[0].terminals[0].sessionId == "")
    }

    @Test func reconcileKeepsRunningRowRemovedFromFileAsLocalOnly() async throws {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "s1", windowId: "w1"),
            TerminalHandle(sessionId: "s2", windowId: "w1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])
        await store.openClaude(for: store.projects[0]) // slot "Claude 1", session s1
        await store.openClaude(for: store.projects[0]) // slot "Claude 2", session s2

        // Simulate an external edit that drops Claude 2.
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [.init(slot: "Claude 1", type: "claude")], terminals: []),
            in: folder
        )
        let dropped = store.projects[0].terminals[1].id
        store.reconcileWithFile(store.projects[0].id)

        #expect(store.projects[0].terminals.map(\.slot) == ["Claude 1", "Claude 2"])
        #expect(store.localOnlyTerminals.contains(dropped))
    }

    @Test func importedRowOpensOnActivate() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "opened-1", windowId: "w1")]
        fake.focusResult = FocusResult(found: false, jobName: nil)
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.addProject(url: folder)

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(store.projects[0].terminals[0].sessionId == "opened-1")
    }

    // A row imported from config has no pane yet, so there is nothing to focus
    // and activating it must neither ask the service nor raise an error.
    @Test func importedRowActivatesWithoutFocusingAnEmptySession() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "opened-1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.addProject(url: folder)

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.focusCalls.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.projects[0].terminals[0].sessionId == "opened-1")
    }

    /// A row with no pane must open even when the service answers "found".
    ///
    /// `importedRowOpensOnActivate` above pins the same behaviour with a service
    /// that answers "not found". Both are needed: a service free to resolve an empty
    /// id to something of its own would report a live session for a row that had
    /// none, `activate` would skip the open, and the row would stay empty forever.
    /// The empty session id has to be recognised before anything is asked about
    /// it.
    @Test func importedRowOpensOnActivateEvenWhenFocusClaimsItIsAlive() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "opened-1", windowId: "w1")]
        fake.focusResult = FocusResult(found: true, jobName: "sleep")
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.addProject(url: folder)

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(store.projects[0].terminals[0].sessionId == "opened-1")
        #expect(fake.focusCalls.isEmpty)
        #expect(fake.openCalls.count == 1)
    }

    /// A Claude row with no pane gets its command from `open`, not from a send
    /// into a pane that does not exist.
    /// A row imported from the config file starts the same way as one opened by
    /// hand: a shell, with the agent typed into it. This test used to pin the
    /// opposite, which is how the fourth door into the same room was found.
    @Test func importedClaudeRowOpensAsAShellAndTypesTheAgent() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "opened-1", windowId: "w1")]
        fake.focusResult = FocusResult(found: true, jobName: "sleep")
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [.init(slot: "Claude 1", type: "claude")], terminals: []),
            in: folder
        )
        store.addProject(url: folder)

        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.openCalls.map(\.command) == [nil])
        #expect(fake.sendCalls.map(\.text) == ["claude\n"])
    }

    /// The in-app terminal window is keyed by pane id alone, so a row with no
    /// pane must not hand one out. An empty id opened a window that could never
    /// show anything, and `terminal(paneId:)` matched the first paneless row for
    /// any empty lookup.
    @Test func aRowWithNoPaneHasNoPaneId() async throws {
        let fake = FakeTerminalService()
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.addProject(url: folder)

        #expect(store.projects[0].terminals[0].sessionId.isEmpty)
        #expect(store.currentPaneId(of: store.projects[0].terminals[0]) == nil)
        #expect(store.terminal(paneId: "") == nil)
    }

    // Removing an imported row must not ask the terminal service to close a
    // session that was never opened; the row still disappears.
    @Test func closingImportedRowWithoutSessionSkipsTheBridge() async throws {
        let fake = FakeTerminalService()
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.addProject(url: folder)

        await store.closeTerminal(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.closeCalls.isEmpty)
        #expect(store.lastError == nil)
        #expect(store.projects[0].terminals.isEmpty)
    }

    @Test func changeSignalSetWhenDiskDiffersAndClearedOnApply() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])
        let id = store.projects[0].id

        // External edit adds a terminal, then simulate the watcher firing.
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.configFileDidChange(id)
        #expect(store.configChangedOnDisk.contains(id))

        store.applyConfigChanges(for: store.projects[0])
        #expect(store.configChangedOnDisk.contains(id) == false)
        #expect(store.projects[0].terminals.map(\.slot) == ["Terminal 1"])
    }

    @Test func editedNameOnDiskAppliesAfterApply() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: "old", agents: [], terminals: []),
            in: folder
        )
        store.addProject(url: folder)
        let id = store.projects[0].id
        #expect(store.projects[0].name == "old")

        // External edit changes only the name, then simulate the watcher firing.
        try ConfigFile.write(
            WorkspaceConfig(name: "new", agents: [], terminals: []),
            in: folder
        )
        store.configFileDidChange(id)
        #expect(store.configChangedOnDisk.contains(id))

        store.applyConfigChanges(for: store.projects[0])
        #expect(store.configChangedOnDisk.contains(id) == false)
        #expect(store.projects[0].name == "new")
    }

    @Test func ownWriteDoesNotRaiseSignal() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])
        let id = store.projects[0].id

        await store.openTerminal(for: store.projects[0]) // app write updates lastConfigData
        store.configFileDidChange(id)
        #expect(store.configChangedOnDisk.contains(id) == false)
    }

    @Test func fileDeleteDisablesSync() async throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])
        let id = store.projects[0].id

        try FileManager.default.removeItem(at: ConfigFile.url(in: folder))
        store.configFileDidChange(id)
        #expect(store.isSyncEnabled(store.projects[0]) == false)
        #expect(store.configChangedOnDisk.contains(id) == false)
    }

    @Test func configNameOverridesFolderName() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: "laravel-test", agents: [], terminals: []),
            in: folder
        )
        store.addProject(url: folder)
        #expect(store.projects[0].name == "laravel-test")
    }

    @Test func noConfigNameUsesFolderName() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: []),
            in: folder
        )
        store.addProject(url: folder)
        #expect(store.projects[0].name == folder.lastPathComponent)
    }

    @Test func committedNameSurvivesStructuralChange() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: "keep-me", agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.addProject(url: folder)

        await store.openTerminal(for: store.projects[0])

        let config = try ConfigFile.read(in: folder)
        #expect(config?.name == "keep-me")
    }

    @Test func enableThenReconcileRoundTripsName() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        try ConfigFile.write(
            WorkspaceConfig(name: "round-trip", agents: [], terminals: []),
            in: folder
        )
        store.addProject(url: folder)

        await store.openTerminal(for: store.projects[0])
        let config = try ConfigFile.read(in: folder)
        #expect(config?.name == "round-trip")
        #expect(store.projects[0].name == "round-trip")
    }

    @Test func recreatedFileAfterDeleteRaisesSignalAgain() async throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])
        let id = store.projects[0].id

        try FileManager.default.removeItem(at: ConfigFile.url(in: folder))
        store.configFileDidChange(id)
        #expect(store.configChangedOnDisk.contains(id) == false)

        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.configFileDidChange(id)
        #expect(store.configChangedOnDisk.contains(id))
    }

    @Test func applyDoesNotClearSignalWhenFileMalformed() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        store.enableConfigSync(for: store.projects[0])
        let id = store.projects[0].id

        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"]),
            in: folder
        )
        store.configFileDidChange(id)
        #expect(store.configChangedOnDisk.contains(id))

        try Data("{ not json".utf8).write(to: ConfigFile.url(in: folder))
        store.applyConfigChanges(for: store.projects[0])
        #expect(store.configChangedOnDisk.contains(id))
        #expect(store.lastError != nil)
    }

    /// The alert shows `lastError` alone, with nothing around it to say which
    /// workspace it came from, and a watcher can fire it for a workspace the user
    /// is not looking at. So the folder has to be named in the message itself.
    @Test func aBadConfigFileNamesItsWorkspaceAndTheMissingKey() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = tempFolder()
        store.addProject(url: folder)

        try Data("""
        { "name": "x", "agents": [], "iterm": ["Terminal 1"] }
        """.utf8).write(to: ConfigFile.url(in: folder))
        #expect(store.reconcileWithFile(store.projects[0].id) == false)

        let message = try #require(store.lastError)
        #expect(message.contains(folder.lastPathComponent))
        #expect(message.contains("terminals"))
    }

    @Test func processesBlockSurvivesConfigEmit() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(
            defaults: makeDefaults(), service: fake,
            processSupervisor: ProcessSupervisor(launcher: FakeProcessLauncher())
        )
        let folder = tempFolder()
        let processes = ["web": ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down", status: "sail ps")]
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"], processes: processes),
            in: folder
        )
        store.addProject(url: folder)
        #expect(store.projects[0].configProcesses == processes)

        // Trigger an emit (a structural mutation with sync already on, since
        // adding a project with an existing config file scaffolds rows but
        // doesn't itself write).
        store.rename(store.projects[0].terminals[0], in: store.projects[0], to: "server")

        let config = try ConfigFile.read(in: folder)
        #expect(config?.processes == processes)
        #expect(config?.terminals == ["server"])
    }

    @Test func testsBlockSurvivesConfigEmit() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        let tests = ["phpstan": TestConfig(command: "phpstan analyse")]
        try ConfigFile.write(
            WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"], tests: tests),
            in: folder
        )
        store.addProject(url: folder)
        #expect(store.projects[0].configTests == tests)

        // Trigger an emit (a structural mutation with sync already on, since
        // adding a project with an existing config file scaffolds rows but
        // doesn't itself write).
        store.rename(store.projects[0].terminals[0], in: store.projects[0], to: "server")

        let config = try ConfigFile.read(in: folder)
        #expect(config?.tests == tests)
        #expect(config?.terminals == ["server"])
    }

    @Test func renamingClaudeKeepsSlotStable() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        let folder = tempFolder()
        store.addProject(url: folder)
        await store.openClaude(for: store.projects[0])

        let ref = store.projects[0].terminals[0]
        store.rename(ref, in: store.projects[0], to: "fix bug")

        #expect(store.projects[0].terminals[0].label == "fix bug")
        #expect(store.projects[0].terminals[0].slot == "Claude 1")
    }

    @Test func workspaceCardAcceptsSyncParameters() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: tempFolder())
        let project = store.projects[0]
        _ = WorkspaceCardView(
            project: project,
            collapsed: false,
            gitInfo: nil,
            runState: { store.runState(for: $0) },
            needsAttention: { store.attention.contains($0.id) },
            syncEnabled: store.isSyncEnabled(project),
            configChanged: store.configChangedOnDisk.contains(project.id),
            isLocalOnly: { store.localOnlyTerminals.contains($0.id) },
            onActivate: { _ in },
            onRestartTerminal: { _ in },
            onRenameTerminal: { _ in },
            onRemoveTerminal: { _ in },
            onCloseTerminal: { _ in },
            onOpenTerminal: {},
            onOpenClaude: {},
            onRemoveProject: {},
            onToggleCollapsed: {},
            onEnableSync: {},
            onApplyConfig: {},
            processes: [],
            onProcessStart: { _ in },
            onProcessStop: { _ in },
            onProcessRestart: { _ in },
            onProcessKill: { _ in },
            onOpenProcessLog: { _ in },
            tests: [],
            onTestRun: { _ in },
            onTestRunAll: {},
            onOpenTestLog: { _ in }
        )
    }
}
