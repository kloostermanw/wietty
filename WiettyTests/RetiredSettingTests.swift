import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// A setting Wietty no longer has, in a config file that still has its line.
///
/// `show-workspace-badge` was removed: it labelled terminals with their workspace's
/// name when terminals were another application's windows, and did nothing once
/// they were libghostty surfaces. Every config file written before that holds the
/// line, so it has to load, and the rule for what happens to the line is here: it
/// is read past, left alone by a launch, and dropped by the next write
/// (`SettingsKeys.retired`).
@MainActor
@Suite struct RetiredSettingTests {
    /// A file as a build with the setting wrote it, with a comment and a key of the
    /// user's own.
    private static func olderFile(badge: String) -> String {
        """
        # mine
        show-workspace-badge = \(badge)
        bell-sound = default
        notification-source = osc-9-777
        check-interval-fast = 15
        check-interval-normal = 60
        check-interval-slow = 300
        sidebar-width = 283.0
        remote-enabled = true
        remote-port = 9100
        mcp-port = 4100
        scrollback-lines = 25000
        something-else = kept

        """
    }

    private func config(badge: String) throws -> WiettyConfigFile {
        let config = WiettyConfigFile.temporary()
        try FileManager.default.createDirectory(at: config.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.olderFile(badge: badge).write(to: config.url, atomically: true, encoding: .utf8)
        return config
    }

    /// Whatever the line says, the file loads and every other setting in it is read.
    @Test(arguments: ["true", "false", "", "not a boolean"])
    func aFileThatStillHasTheKeyLoads(badge: String) throws {
        let config = try config(badge: badge)
        let fixture = SettingsFixture(config: config)

        #expect(fixture.store.lastError == nil)
        #expect(fixture.store.remoteEnabled)
        #expect(fixture.store.remotePort == 9100)
        #expect(fixture.store.mcpPort == 4100)
        #expect(fixture.store.scrollbackLines == 25_000)
    }

    /// A launch writes nothing, so the line is still there after one.
    @Test func aLaunchLeavesTheFileAsItWas() throws {
        let config = try config(badge: "true")
        _ = SettingsFixture(config: config)
        #expect(try String(contentsOf: config.url, encoding: .utf8) == Self.olderFile(badge: "true"))
    }

    /// The first change of any setting rewrites the managed lines, and the retired
    /// one goes with it. The comment and the key Wietty does not know stay.
    @Test func theNextWriteDropsTheLineAndNothingElse() throws {
        let config = try config(badge: "true")
        let fixture = SettingsFixture(config: config)
        fixture.store.mcpPort = 4101

        let text = try String(contentsOf: config.url, encoding: .utf8)
        #expect(!text.contains("show-workspace-badge"))
        #expect(text.contains("# mine"))
        let values = try config.read()
        #expect(values["something-else"] == "kept")
        #expect(values["mcp-port"] == "4101")
        #expect(values["remote-port"] == "9100")
        #expect(values["scrollback-lines"] == "25000")
        #expect(values["sidebar-width"] == "283.0")
    }

    /// And the store built from the rewritten file reads what the first one had.
    @Test func theRewrittenFileLoadsTheSame() throws {
        let config = try config(badge: "true")
        SettingsFixture(config: config).store.mcpPort = 4101
        let again = SettingsFixture(config: config).store
        #expect(again.mcpPort == 4101)
        #expect(again.remotePort == 9100)
        #expect(again.scrollbackLines == 25_000)
    }

    /// A retired key is nobody's: not a scalar a source owns or emits, and not in the
    /// file's order. That is what keeps the writer from preserving it as the setting
    /// of a source that has not registered yet.
    @Test func noSourceOwnsOrEmitsARetiredKey() {
        let fixture = SettingsFixture(config: WiettyConfigFile.temporary())
        #expect(SettingsKeys.retired == ["show-workspace-badge"])
        #expect(SettingsKeys.retired.isDisjoint(with: SettingsKeys.scalars))
        #expect(SettingsKeys.retired.isDisjoint(with: SettingsKeys.fileOrder))
        #expect(SettingsKeys.retired.isDisjoint(with: fixture.store.ownedKeys))
        #expect(SettingsKeys.retired.isDisjoint(with: fixture.preferences.ownedKeys))
        let emitted = Set((fixture.store.settingsPairs + fixture.preferences.settingsPairs).map(\.key))
        #expect(SettingsKeys.retired.isDisjoint(with: emitted))
    }
}
