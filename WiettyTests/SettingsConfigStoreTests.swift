import Testing
import Foundation
@testable import Wietty

/// The store's settings now live in `~/.config/wietty/config` rather than
/// `UserDefaults`. These assert where each setting lands, that secrets never do, and
/// that an upgrade migrates the old `UserDefaults` values without loss.
@MainActor
@Suite struct SettingsConfigStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Scalars

    @Test func scalarSettingsAreWrittenToTheConfigFile() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        store.showWorkspaceBadge = true
        store.bellSound = .named("Ping")
        store.checkIntervals = CheckIntervals(fast: 20, normal: 90, slow: 400)
        store.sidebarWidth = 350
        store.remoteEnabled = true
        store.remotePort = 9100
        store.mcpPort = 4100

        let values = (try config.read())
        #expect(values["show-workspace-badge"] == "true")
        #expect(values["bell-sound"] == BellSound.named("Ping").stored)
        #expect(values["check-interval-fast"] == "20")
        #expect(values["check-interval-normal"] == "90")
        #expect(values["check-interval-slow"] == "400")
        #expect(values["sidebar-width"] == "350.0")
        #expect(values["remote-enabled"] == "true")
        #expect(values["remote-port"] == "9100")
        #expect(values["mcp-port"] == "4100")
    }

    @Test func scalarSettingsRoundTripAcrossInstances() {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.remotePort = 9100
        store1.bellSound = .named("Submarine")
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.remotePort == 9100)
        #expect(store2.bellSound == .named("Submarine"))
    }

    // MARK: Secrets stay out

    /// The remote access token is a secret and stays in `UserDefaults`. A plaintext
    /// config file the user is invited to edit must never hold it.
    @Test func theRemoteTokenIsNeverWrittenToTheConfigFile() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        let token = store.remoteToken.value   // generate it
        store.remoteEnabled = true            // force a settings write

        let text = (try? String(contentsOf: config.url, encoding: .utf8)) ?? ""
        #expect(!text.contains(token))
        #expect(!(try config.read()).keys.contains { $0.contains("token") })
    }

    // MARK: Agents

    @Test func agentsAreWrittenAsIndexedKeys() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        store.agents = [
            AgentDefinition(name: "Claude", command: "claude"),
            AgentDefinition(name: "Aider", command: "aider", defaultArguments: "--yes"),
        ]
        let values = (try config.read())
        #expect(values["agent.0.name"] == "Claude")
        #expect(values["agent.0.command"] == "claude")
        #expect(values["agent.1.name"] == "Aider")
        #expect(values["agent.1.command"] == "aider")
        #expect(values["agent.1.args"] == "--yes")
    }

    @Test func agentsRoundTripAcrossInstances() {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.agents = [AgentDefinition(name: "Aider", command: "aider", defaultArguments: "--yes")]
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.agents.count == 1)
        #expect(store2.agents.first?.name == "Aider")
        #expect(store2.agents.first?.defaultArguments == "--yes")
    }

    // MARK: Approved commands

    @Test func approvedCommandsAreWrittenPerWorkspaceUUID() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        let id = UUID()
        store.approve(["npm test", "make build"], for: id)

        let values = (try config.read())
        let approved = values.filter { $0.key.hasPrefix("approved.\(id.uuidString).") }
        #expect(Set(approved.values) == ["npm test", "make build"])
    }

    @Test func approvedCommandsRoundTripAcrossInstances() {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let id = UUID()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.approve(["npm test"], for: id)
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.approvedCommands[id] == ["npm test"])
    }

    // MARK: Workspaces

    @Test func workspacesAreWrittenAsPlainPaths() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        let folder = makeFolder()
        store.addProject(url: folder)

        let values = (try config.read())
        #expect(values["workspace.0.path"] == folder.standardizedFileURL.path)
    }

    /// No security-scoped bookmark blob is written: the file is text, and the point of
    /// the move is that a person can read and edit it.
    @Test func workspacesDoNotWriteBookmarkData() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        store.addProject(url: makeFolder())
        let text = try String(contentsOf: config.url, encoding: .utf8)
        #expect(!text.contains("bookmark"))
    }

    @Test func workspacesRoundTripAcrossInstances() {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let folder = makeFolder()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.addProject(url: folder)
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.projects.count == 1)
        #expect(store2.projects.first?.url.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    // MARK: Migration

    /// On the first launch after the change, existing `UserDefaults` values are read,
    /// written to the config file, and then read from the file thereafter.
    @Test func scalarsMigrateFromUserDefaultsWhenTheFileIsAbsent() throws {
        let defaults = makeDefaults()
        defaults.set(9100, forKey: "wietty.remotePort")
        defaults.set("named:Submarine", forKey: "wietty.bellSound")
        defaults.set(true, forKey: "wietty.showWorkspaceBadge")

        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())

        #expect(store.remotePort == 9100)
        #expect(store.bellSound == .named("Submarine"))
        #expect(store.showWorkspaceBadge)
        #expect((try config.read())["remote-port"] == "9100")
    }

    /// After migrating a value, the old `UserDefaults` key is removed so nothing reads
    /// it again and the two do not drift.
    @Test func migrationRemovesTheOldUserDefaultsKeys() {
        let defaults = makeDefaults()
        defaults.set(9100, forKey: "wietty.remotePort")
        let config = WiettyConfigFile.temporary()
        _ = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(defaults.object(forKey: "wietty.remotePort") == nil)
    }

    /// The agent list an older build stored as JSON in `UserDefaults` survives the
    /// move to the config file.
    @Test func agentsMigrateFromUserDefaultsWhenTheFileIsAbsent() throws {
        let defaults = makeDefaults()
        let stored = [AgentDefinition(name: "Aider", command: "aider", defaultArguments: "--yes")]
        defaults.set(try JSONEncoder().encode(stored), forKey: "wietty.agents")

        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())

        #expect(store.agents.map(\.name) == ["Aider"])
        #expect((try config.read())["agent.0.command"] == "aider")
    }

    /// The mirror of the shape older builds wrote to `wietty.projects.bookmarks`: an
    /// array of these, JSON encoded, each a security-scoped bookmark plus its rows.
    private struct LegacyWorkspace: Encodable {
        var id: UUID, bookmark: Data, terminals: [TerminalRef]
        var terminalSeq: Int, claudeSeq: Int
        var displayName: String?, windowId: String?, collapsed: Bool
    }

    /// A workspace stored as a security-scoped bookmark migrates to a plain path with
    /// its rows intact.
    @Test func workspacesMigrateFromBookmarkDefaults() throws {
        let defaults = makeDefaults()
        let folder = makeFolder()
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = LegacyWorkspace(
            id: UUID(), bookmark: bookmark,
            terminals: [TerminalRef(label: "Terminal 1", sessionId: "sess-A")],
            terminalSeq: 1, claudeSeq: 0, displayName: "Renamed", windowId: nil, collapsed: false
        )
        defaults.set([try JSONEncoder().encode(record)], forKey: "wietty.projects.bookmarks")

        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())

        #expect(store.projects.count == 1)
        #expect(store.projects.first?.url.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(store.projects.first?.name == "Renamed")
        #expect(store.projects.first?.terminals.first?.sessionId == "sess-A")
        #expect((try config.read())["workspace.0.path"] == folder.standardizedFileURL.path)
    }

    /// A present but unreadable config (corrupt bytes, a bad hand-edit) must not be
    /// silently reset: the store loads defaults so the app still opens, but it does not
    /// overwrite the file, and it says so. A later settings change must not clobber it
    /// either.
    @Test func anUnreadableConfigIsNotOverwrittenWithDefaults() throws {
        let config = WiettyConfigFile.temporary()
        try FileManager.default.createDirectory(at: config.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let corrupt = Data([0xFF, 0xFE, 0x00, 0x01])
        try corrupt.write(to: config.url)

        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        #expect(store.lastError != nil)

        // A change that would normally persist must be a no-op against the bad file.
        store.remotePort = 7000
        #expect(try Data(contentsOf: config.url) == corrupt)
    }

    /// If the first-launch seed write fails, the old `UserDefaults` keys must stay:
    /// removing them would leave no copy of the user's data anywhere.
    @Test func aFailedMigrationWriteKeepsTheOldDefaultsKeys() {
        let defaults = makeDefaults()
        defaults.set(9100, forKey: "wietty.remotePort")
        // A parent path that is a file, not a directory, so creating the config dir fails.
        let unwritable = WiettyConfigFile(url: URL(fileURLWithPath: "/dev/null/wietty/config"))
        let store = ProjectStore(defaults: defaults, config: unwritable, service: FakeTerminalService())

        #expect(defaults.object(forKey: "wietty.remotePort") as? Int == 9100)
        #expect(store.lastError != nil)
    }

    /// Deleting the file resets these settings to their defaults on the next launch,
    /// because the migrated `UserDefaults` keys are gone and the file-absent path falls
    /// back to true defaults. Workspaces are emptied for the same reason.
    @Test func deletingTheFileResetsSettingsToDefaults() throws {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.remotePort = 9100
        store1.addProject(url: makeFolder())

        try FileManager.default.removeItem(at: config.url)

        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.remotePort == RemoteServer.defaultPort)
        #expect(store2.projects.isEmpty)
    }

    /// A hand-edited file with garbage or out-of-range values falls back or clamps on
    /// read rather than crashing or carrying the bad value.
    @Test func malformedValuesFallBackOrClampOnRead() throws {
        let config = WiettyConfigFile.temporary()
        try FileManager.default.createDirectory(at: config.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try """
        remote-port = notanumber
        mcp-port = 70000
        sidebar-width = 0
        """.write(to: config.url, atomically: true, encoding: .utf8)

        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        #expect(store.remotePort == RemoteServer.defaultPort)   // unparseable -> default
        #expect(store.mcpPort == ProjectStore.portRange.upperBound) // out of range -> clamped
        #expect(store.sidebarWidth == SidebarWidth.default)     // impossible width -> default
    }

    /// An approved command carrying an `=` (an env-var prefix like `FOO=bar make`)
    /// round-trips, since the parser splits on the first `=`.
    @Test func approvedCommandWithEqualsRoundTrips() {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let id = UUID()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.approve(["FOO=bar make build"], for: id)
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.approvedCommands[id] == ["FOO=bar make build"])
    }

    /// The remote token is not migrated: it stays exactly where it was.
    @Test func migrationLeavesTheRemoteTokenInUserDefaults() {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        let token = store.remoteToken.value
        // A fresh store on the same defaults sees the same token, proving it persisted
        // in UserDefaults rather than only in memory.
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(store2.remoteToken.value == token)
    }
}
