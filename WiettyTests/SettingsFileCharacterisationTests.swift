import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// What `~/.config/wietty/config` looks like, byte for byte.
///
/// Every other settings test asks whether a key holds the right value. This one
/// asks a different question: does the file come out with exactly these lines, in
/// exactly this order. That matters because phase 1 splits the one writer in
/// `ProjectStore` into a `SettingsWriter` fed by two sources, and the promise made
/// to the owner is that the file does not move. A test that reads keys back would
/// pass even if every block swapped places, because `WiettyConfigFile.write`
/// rewrites managed lines at the end of the file in the order it is given them.
///
/// Written against a temporary file, never the real one: the suite runs inside a
/// host app on a machine where Wietty itself may be running, and the config in the
/// user's home is theirs.
///
/// Ids and temporary paths are the only things normalised, because they are random
/// per run and carry no ordering information. Everything else is asserted literally.
@MainActor
@Suite struct SettingsFileCharacterisationTests {

    /// Replaces each distinct UUID with `<uuid-N>`, numbered by first appearance, and
    /// the fixture's parent directory with `<dir>`. Order is preserved exactly, so a
    /// block that moved still fails the comparison.
    private func normalised(_ text: String, root: URL) -> String {
        var out = text.replacingOccurrences(of: root.standardizedFileURL.path, with: "<dir>")
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        let regex = try! NSRegularExpression(pattern: pattern)
        var seen: [String: String] = [:]
        while let match = regex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let range = Range(match.range, in: out) {
            let found = String(out[range])
            let name = seen[found] ?? "<uuid-\(seen.count)>"
            seen[found] = name
            out = out.replacingOccurrences(of: found, with: name)
        }
        return out
    }

    @Test func theConfigFileIsWrittenWithExactlyTheseLinesInThisOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("characterisation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alpha = root.appendingPathComponent("alpha")
        let beta = root.appendingPathComponent("beta")
        for url in [alpha, beta] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let config = WiettyConfigFile.temporary()
        let fixture = SettingsFixture(config: config)
        let store = fixture.store
        let preferences = fixture.preferences

        // One of each kind of setting the writer emits, so a block that moves is caught.
        store.showWorkspaceBadge = true
        preferences.bellSound = .named("Ping")
        store.notificationSource = .programStatus
        store.checkIntervals = CheckIntervals(fast: 20, normal: 90, slow: 400)
        preferences.sidebarWidth = 350
        store.remoteEnabled = true
        store.remotePort = 9100
        store.mcpPort = 4100
        preferences.sidebarColors = SidebarColors(background: ColorHex.color(from: "#102030"),
                                            foreground: ColorHex.color(from: "#a0b0c0"))
        store.agents = [AgentDefinition(name: "Claude", command: "claude", defaultArguments: "--verbose"),
                        AgentDefinition(name: "Codex", command: "codex", defaultArguments: "")]
        let research = WorkspaceGroup(name: "Research")
        store.groups = [research, WorkspaceGroup(name: "Shipping")]
        preferences.selectedGroupId = research.id
        store.addProject(url: alpha)
        store.addProject(url: beta)
        store.assignGroup(store.projects[0], to: research.id)

        let text = try String(contentsOf: config.url, encoding: .utf8)
        #expect(normalised(text, root: root) == """
        # Managed by Wietty. Hand-editable: key = value, one per line, # starts a comment. Secrets are never written here.
        show-workspace-badge = true
        bell-sound = named:Ping
        notification-source = osc-7501
        check-interval-fast = 20
        check-interval-normal = 90
        check-interval-slow = 400
        sidebar-width = 350.0
        remote-enabled = true
        remote-port = 9100
        mcp-port = 4100
        color-background = #102030
        color-foreground = #a0b0c0
        agent.0.name = Claude
        agent.0.command = claude
        agent.0.args = --verbose
        agent.1.name = Codex
        agent.1.command = codex
        agent.1.args = 
        group.0.id = <uuid-0>
        group.0.name = Research
        group.1.id = <uuid-1>
        group.1.name = Shipping
        selected-group = <uuid-0>
        workspace.0.path = <dir>/alpha
        workspace.0.id = <uuid-2>
        workspace.0.collapsed = false
        workspace.0.terminal-seq = 0
        workspace.0.claude-seq = 0
        workspace.0.group-id = <uuid-0>
        workspace.1.path = <dir>/beta
        workspace.1.id = <uuid-3>
        workspace.1.collapsed = false
        workspace.1.terminal-seq = 0
        workspace.1.claude-seq = 0

        """)

        try? FileManager.default.removeItem(at: root)
    }
}

/// What a launch does to a config file that already holds every setting.
///
/// Splitting the writer put a window between the store registering itself and
/// `UIPreferences` registering: the store's own init and its first actions can write,
/// and `WiettyConfigFile.write` removes every managed key the pairs it is handed do
/// not mention. A write in that window would therefore delete the four settings that
/// moved, which is a user losing their sidebar colours and width on launch.
@MainActor
@Suite struct SettingsLaunchPreservationTests {
    @Test func aLaunchThatClearsDeadSessionsKeepsTheMovedSettings() throws {
        let config = WiettyConfigFile.temporary()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // A file as a real one looks: the four that moved, and a workspace carrying a
        // session id, which is what makes the next launch write.
        try config.write([
            ("bell-sound", "named:Ping"),
            ("sidebar-width", "283.0"),
            ("color-background", "#23292b"),
            ("workspace.0.path", folder.path),
            ("workspace.0.id", UUID().uuidString),
            ("workspace.0.collapsed", "false"),
            ("workspace.0.terminal-seq", "1"),
            ("workspace.0.claude-seq", "0"),
            ("workspace.0.terminal.0.id", UUID().uuidString),
            ("workspace.0.terminal.0.label", "shell1"),
            ("workspace.0.terminal.0.kind", "terminal"),
            ("workspace.0.terminal.0.slot", "shell1"),
            ("workspace.0.terminal.0.session-id", "gt:dead"),
        ], managedKeys: SettingsKeys.scalars, managedPrefixes: SettingsKeys.prefixes)

        let fixture = SettingsFixture(config: config)
        #expect(fixture.preferences.bellSound == .named("Ping"))
        fixture.store.clearDeadSessions()

        let values = try config.read()
        #expect(values["bell-sound"] == "named:Ping")
        #expect(values["sidebar-width"] == "283.0")
        #expect(values["color-background"] == "#23292b")
        #expect(values["workspace.0.terminal.0.session-id"] == nil)

        try? FileManager.default.removeItem(at: folder)
    }
}

/// A settings source that is not registered must not cost the user its settings.
@MainActor
@Suite struct SettingsWriterPreservationTests {
    @Test func aWriteWithOnlyTheStoreRegisteredKeepsTheOtherSourcesSettings() throws {
        let config = WiettyConfigFile.temporary()
        try config.write([("bell-sound", "named:Ping"),
                          ("sidebar-width", "283.0"),
                          ("color-background", "#23292b"),
                          ("group.0.id", UUID().uuidString),
                          ("group.0.name", "Gone")],
                         managedKeys: SettingsKeys.scalars, managedPrefixes: SettingsKeys.prefixes)

        // The store alone, as during the window before UIPreferences registers.
        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 config: config, service: FakeTerminalService())
        store.addGroup(WorkspaceGroup(name: "Kept"))   // forces a write

        let values = try config.read()
        #expect(values["bell-sound"] == "named:Ping")
        #expect(values["sidebar-width"] == "283.0")
        #expect(values["color-background"] == "#23292b")
        // The store owns the group list, so it rewrites the whole thing: the one the
        // file held is loaded and kept, and the new one is appended.
        #expect(values["group.0.name"] == "Gone")
        #expect(values["group.1.name"] == "Kept")

        // And the list still prunes, which is why preservation is limited to scalars.
        store.removeGroup(id: store.groups[0].id)
        let pruned = try config.read()
        #expect(pruned["group.0.name"] == "Kept")
        #expect(pruned["group.1.name"] == nil)
        #expect(pruned["bell-sound"] == "named:Ping")
    }
}
