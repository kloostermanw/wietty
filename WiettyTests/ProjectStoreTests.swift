import Testing
import Foundation
@testable import Wietty

/// Shared by every suite in this file: `ProjectStoreDeadSessionTests` needs the
/// same construction as `ProjectStoreTests`, so these are factored out here
/// rather than duplicated per suite.
private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "test.\(UUID().uuidString)")!
}

private func makeTempFolder(named name: String) -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let url = base.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite @MainActor struct ProjectStoreTests {
    @Test func addingFolderAppendsProjectWithFolderName() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "my-project"))
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "my-project")
    }

    /// The store rewrites the whole file from its own state whenever rows change,
    /// so a key it does not carry would be silently deleted from the user's file.
    @Test func rewritingTheConfigPreservesTopLevelShellInit() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder(named: "prelude")
        let onDisk = WorkspaceConfig(
            name: nil, agents: [], terminals: ["Terminal 1", "Terminal 2"],
            shellInit: ["export PATH=$HOME/bin:$PATH", "source ~/bin/env.sh"]
        )
        _ = try ConfigFile.write(onDisk, in: folder)
        store.addProject(url: folder)
        store.reconcileWithFile(try #require(store.projects.first).id)

        let project = try #require(store.projects.first)
        let row = try #require(project.terminals.first)
        store.removeTerminal(row, in: project)

        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.shellInit == ["export PATH=$HOME/bin:$PATH", "source ~/bin/env.sh"])
        #expect(reread.terminals == ["Terminal 2"]) // the row change did land
    }

    /// The supervisor folds the workspace wide lines into each definition before
    /// running it. A rewrite must not write that merge back, or every process
    /// would accumulate a copy of the global prelude on disk.
    @Test func rewritingTheConfigKeepsProcessShellInitUnmerged() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder(named: "unmerged")
        let onDisk = WorkspaceConfig(
            name: nil, agents: [], terminals: ["Terminal 1", "Terminal 2"],
            processes: ["worker": ProcessConfig(command: "python worker.py", shellInit: ["source ./.venv/bin/activate"])],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        _ = try ConfigFile.write(onDisk, in: folder)
        store.addProject(url: folder)
        store.reconcileWithFile(try #require(store.projects.first).id)

        let project = try #require(store.projects.first)
        store.removeTerminal(try #require(project.terminals.first), in: project)

        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.processes?["worker"]?.shellInit == ["source ./.venv/bin/activate"])
        #expect(reread.shellInit == ["export PATH=$HOME/bin:$PATH"])
    }

    /// The `tests` section travels the same rewrite path as `processes`, so it
    /// needs the same guard: a test's own lines must come back exactly as written,
    /// without the workspace wide lines folded in.
    @Test func rewritingTheConfigKeepsTestShellInitUnmerged() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder(named: "unmerged-tests")
        let onDisk = WorkspaceConfig(
            name: nil, agents: [], terminals: ["Terminal 1", "Terminal 2"],
            tests: ["phpstan": TestConfig(
                command: "vendor/bin/phpstan analyse", shellInit: ["source ./.venv/bin/activate"]
            )],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        _ = try ConfigFile.write(onDisk, in: folder)
        store.addProject(url: folder)
        store.reconcileWithFile(try #require(store.projects.first).id)

        let project = try #require(store.projects.first)
        store.removeTerminal(try #require(project.terminals.first), in: project)

        let reread = try #require(try ConfigFile.read(in: folder))
        #expect(reread.tests?["phpstan"]?.shellInit == ["source ./.venv/bin/activate"])
        #expect(reread.shellInit == ["export PATH=$HOME/bin:$PATH"])
    }

    @Test func addingSameFolderTwiceIsDeduped() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder(named: "dupe")
        store.addProject(url: folder)
        store.addProject(url: folder)
        #expect(store.projects.count == 1)
    }

    @Test func projectsPersistAcrossStoreInstances() {
        let defaults = makeDefaults()
        let a = makeTempFolder(named: "alpha")
        let b = makeTempFolder(named: "beta")
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.addProject(url: a)
        store1.addProject(url: b)
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.map(\.name) == ["alpha", "beta"])
    }

    @Test func projectIdsPersistAcrossStoreInstances() {
        let defaults = makeDefaults()
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.addProject(url: makeTempFolder(named: "alpha"))
        let originalId = store1.projects[0].id
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.first?.id == originalId)
    }

    @Test func removingProjectDropsItFromList() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "keep"))
        store.addProject(url: makeTempFolder(named: "drop"))
        let drop = store.projects.first { $0.name == "drop" }!
        store.remove(drop)
        #expect(store.projects.map(\.name) == ["keep"])
    }

    @Test func removalPersists() {
        let defaults = makeDefaults()
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.addProject(url: makeTempFolder(named: "keep"))
        store1.addProject(url: makeTempFolder(named: "drop"))
        store1.remove(store1.projects.first { $0.name == "drop" }!)
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.map(\.name) == ["keep"])
    }

    @Test func movingReordersAndPersists() {
        let defaults = makeDefaults()
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.addProject(url: makeTempFolder(named: "first"))
        store1.addProject(url: makeTempFolder(named: "second"))
        store1.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store1.projects.map(\.name) == ["second", "first"])
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.map(\.name) == ["second", "first"])
    }

    @Test func moveBeforeReordersProjects() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        store.addProject(url: makeTempFolder(named: "c"))
        let a = store.projects[0].id
        let c = store.projects[2].id
        store.move(id: a, before: c)
        #expect(store.projects.map(\.name) == ["b", "a", "c"])
    }

    @Test func moveBeforeSelfIsNoOp() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        let a = store.projects[0].id
        store.move(id: a, before: a)
        #expect(store.projects.map(\.name) == ["a", "b"])
    }

    @Test func moveBeforeMissingTargetIsNoOp() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        let a = store.projects[0].id
        store.move(id: a, before: UUID())
        #expect(store.projects.map(\.name) == ["a", "b"])
    }

    @Test func moveBeforeMissingSourceIsNoOp() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        let b = store.projects[1].id
        store.move(id: UUID(), before: b)
        #expect(store.projects.map(\.name) == ["a", "b"])
    }

    @Test func moveToEndMovesProjectToLast() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        store.addProject(url: makeTempFolder(named: "c"))
        let a = store.projects[0].id
        store.moveToEnd(id: a)
        #expect(store.projects.map(\.name) == ["b", "c", "a"])
    }

    @Test func moveToEndOnLastIsNoOp() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        let b = store.projects[1].id
        store.moveToEnd(id: b)
        #expect(store.projects.map(\.name) == ["a", "b"])
    }

    @Test func moveToEndMissingIsNoOp() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "a"))
        store.addProject(url: makeTempFolder(named: "b"))
        store.moveToEnd(id: UUID())
        #expect(store.projects.map(\.name) == ["a", "b"])
    }

    @Test func toggleCollapsedFlipsFlag() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "proj"))
        #expect(store.projects[0].collapsed == false)
        store.toggleCollapsed(store.projects[0])
        #expect(store.projects[0].collapsed == true)
        store.toggleCollapsed(store.projects[0])
        #expect(store.projects[0].collapsed == false)
    }

    @Test func collapsedStatePersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.addProject(url: makeTempFolder(named: "proj"))
        store1.toggleCollapsed(store1.projects[0])
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.first?.collapsed == true)
    }

    @Test func newProjectDefaultsToExpandedAfterReload() {
        let defaults = makeDefaults()
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.addProject(url: makeTempFolder(named: "proj"))
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.first?.collapsed == false)
    }

    @Test func toggleCollapsedUnknownProjectIsNoOp() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        store.addProject(url: makeTempFolder(named: "proj"))
        let ghost = Project(url: makeTempFolder(named: "ghost"))
        store.toggleCollapsed(ghost)
        #expect(store.projects[0].collapsed == false)
    }
}

@Suite @MainActor struct ProcessStoreWiringTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    /// Writes an wietty.json with one auto-start process into a temp dir and
    /// returns the folder URL.
    private func makeWorkspace(_ processes: [String: ProcessConfig]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [], processes: processes)
        _ = try ConfigFile.write(config, in: dir)
        return dir
    }

    @Test func applyingConfigDrivesSupervisor() throws {
        let launcher = FakeProcessLauncher()
        let supervisor = ProcessSupervisor(launcher: launcher)
        let store = ProjectStore(
            defaults: makeDefaults(),
            service: FakeTerminalService(),
            gitProvider: FakeGitInfoProvider(),
            processSupervisor: supervisor
        )
        let dir = try makeWorkspace(["npm": ProcessConfig(command: "npm run dev", autoStart: true)])
        store.addProject(url: dir)
        let project = try #require(store.projects.first)
        store.applyConfigChanges(for: project)
        #expect(supervisor.process(projectId: project.id, name: "npm") != nil)
    }
}

/// PTYs die with the app, so on the libghostty substrate every stored session id
/// is dead at launch. The rows have to survive and the ids must not.
///
/// Every test here seeds `UserDefaults` and loads a `ProjectStore` from it,
/// the way `TmuxSessionMigrationTests.SeededProject` seeds
/// `migrateWorkspaceIds()`, the sibling launch reconcile. There is no way to
/// hand a store an already-built row post-construction: `ProjectStore.projects`
/// is `private(set)`, and the two ways a row is genuinely created,
/// `openSessionThrowing` (a live session) and `ConfigReconcile.apply` (an
/// unopened row from the config file), don't let a test dictate a literal
/// session id like `"gt:stale"`. Seeding the persisted shape and loading it
/// through the real initialiser sidesteps both problems.
@MainActor
@Suite struct ProjectStoreDeadSessionTests {
    private let storageKey = "wietty.projects.bookmarks"

    /// The persisted shape of a workspace. Field names match
    /// `ProjectStore.StoredProject`, which is private.
    private struct SeededProject: Codable {
        var id: UUID
        var bookmark: Data
        var terminals: [TerminalRef]
        var terminalSeq: Int
        var claudeSeq: Int
        var windowId: String?
        var collapsed: Bool
    }

    /// Appends one seeded project to whatever `storageKey` already holds, so a
    /// test can seed more than one workspace into the same defaults.
    private func seedProject(_ defaults: UserDefaults, terminals: [TerminalRef],
                              windowId: String? = nil) {
        let folder = makeTempFolder(named: "proj-\(UUID().uuidString)")
        var records = (defaults.array(forKey: storageKey) as? [Data]) ?? []
        let record = SeededProject(id: UUID(), bookmark: try! folder.bookmarkData(),
                                    terminals: terminals, terminalSeq: terminals.count,
                                    claudeSeq: 0, windowId: windowId, collapsed: false)
        records.append(try! JSONEncoder().encode(record))
        defaults.set(records, forKey: storageKey)
    }

    /// An id this build could not have minted is left exactly as it is.
    ///
    /// Those are leftovers from a launch on a terminal the app no longer has, and
    /// they cost nothing: `activate` asks the service to focus one, is told it is
    /// gone, and opens a real terminal in its place. Rewriting them would be work
    /// with no visible effect, and the wipe is meant to answer one question only.
    @Test func anIdThisBuildCouldNotHaveMintedIsLeftAlone() throws {
        let defaults = makeDefaults()
        seedProject(defaults, terminals: [
            TerminalRef(label: "Terminal 1", sessionId: "%3"),
            TerminalRef(label: "Terminal 2", sessionId: "gt:mine"),
            TerminalRef(label: "Claude 1", sessionId: "F4A0C2D1-9E7B", kind: .claude),
        ], windowId: "acme-api-4f2c")
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())

        #expect(store.clearDeadSessions() == 1)
        #expect(store.projects.first?.terminals.map(\.sessionId)
                == ["%3", "", "F4A0C2D1-9E7B"])
        // Persisted that way, not just held in this instance.
        let reloaded = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(reloaded.projects.first?.terminals.first?.sessionId == "%3")
    }

    @Test func everyStoredSessionIdIsCleared() throws {
        let defaults = makeDefaults()
        seedProject(defaults, terminals: [
            TerminalRef(label: "Terminal 1", sessionId: "gt:stale-1"),
            TerminalRef(label: "Claude 1", sessionId: "gt:stale-2", kind: .claude),
        ], windowId: "should-survive")
        seedProject(defaults, terminals: [TerminalRef(label: "Terminal 1", sessionId: "gt:stale-3")])
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())

        let cleared = store.clearDeadSessions()

        // Two projects, three rows between them: a loop that stopped after the
        // first row, or the first project, would still report a count, just
        // the wrong one, which is exactly what "every" rules out.
        #expect(cleared == 3)
        #expect(store.projects.count == 2)
        #expect(store.projects.flatMap(\.terminals).allSatisfy { $0.sessionId.isEmpty })
        // Untouched: nothing reads `windowId`.
        #expect(store.projects.first?.windowId == "should-survive")
        // Persisted, not just held on this one in-memory instance.
        let reloaded = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(reloaded.projects.flatMap(\.terminals).allSatisfy { $0.sessionId.isEmpty })
    }

    /// A row survives its terminal so it can be restarted. Dropping the rows
    /// instead would empty every workspace on every launch.
    @Test func theRowsThemselvesSurvive() throws {
        let defaults = makeDefaults()
        seedProject(defaults, terminals: [TerminalRef(label: "Claude Code", sessionId: "gt:a", kind: .claude)])
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        _ = store.clearDeadSessions()
        #expect(store.projects.first?.terminals.first?.label == "Claude Code")
        #expect(store.projects.first?.terminals.first?.kind == .claude)
    }

    /// A row that was never opened carries no session id, and clearing nothing is
    /// not a change worth persisting or reporting.
    @Test func rowsWithNoSessionAreNotCounted() throws {
        let defaults = makeDefaults()
        seedProject(defaults, terminals: [TerminalRef(label: "Terminal 1", sessionId: "")])
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let before = defaults.array(forKey: storageKey) as? [Data]
        #expect(store.clearDeadSessions() == 0)
        #expect(defaults.array(forKey: storageKey) as? [Data] == before)
    }

    /// `store` is `@State` on `WiettyApp`, one level above the `Window` that
    /// hosts `ContentView`, so it outlives the window: closing and reopening
    /// "Wietty" recreates the view and re-fires its `.task` against the same
    /// store, while a surface `GhosttyStack` opened for real keeps running
    /// underneath it. A second call must not treat that live row's id as a
    /// leftover from before the process started.
    @Test func secondCallInTheSameProcessIsANoOp() async throws {
        let defaults = makeDefaults()
        seedProject(defaults, terminals: [TerminalRef(label: "Terminal 1", sessionId: "gt:stale")])
        let service = FakeTerminalService()
        let store = ProjectStore(defaults: defaults, service: service)
        #expect(store.clearDeadSessions() == 1)

        let project = try #require(store.projects.first)
        await store.openTerminal(for: project)
        let liveId = try #require(store.projects.first?.terminals.last?.sessionId)
        #expect(!liveId.isEmpty)

        #expect(store.clearDeadSessions() == 0)
        #expect(store.projects.first?.terminals.last?.sessionId == liveId)
    }
}
