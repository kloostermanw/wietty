import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The scrollback limit as a setting: `scrollback-lines` in the config file, owned
/// by the store, clamped to `TerminalScrollback.range`.
///
/// What a terminal does with the number is `GhosttyServiceScreenModelTests`. These
/// are about the number itself and the line it lives on.
@MainActor
@Suite struct ScrollbackSettingTests {
    private func store(_ config: WiettyConfigFile) -> ProjectStore {
        SettingsFixture(config: config).store
    }

    /// A config as a real one looks before this setting existed: every scalar the
    /// store and the frontend write at their defaults, a colour, a comment and a key Wietty does not
    /// know. No `scrollback-lines`. It still has `show-workspace-badge`, a setting
    /// since removed (`SettingsKeys.retired`), as any file of that age does.
    private static let olderFile = """
        # mine
        show-workspace-badge = false
        bell-sound = default
        notification-source = osc-9-777
        check-interval-fast = 15
        check-interval-normal = 60
        check-interval-slow = 300
        sidebar-width = 283.0
        remote-enabled = true
        remote-port = 7434
        mcp-port = 7433
        color-background = #23292b
        something-else = kept

        """

    /// A temporary config holding `olderFile`. Written directly rather than through
    /// `WiettyConfigFile.write`, which would add its header and reorder the lines.
    private func olderConfig() throws -> WiettyConfigFile {
        let config = WiettyConfigFile.temporary()
        try FileManager.default.createDirectory(at: config.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.olderFile.write(to: config.url, atomically: true, encoding: .utf8)
        return config
    }

    @Test func theDefaultIsTenThousandLines() {
        #expect(TerminalScrollback.defaultLines == 10_000)
        #expect(TerminalScrollback.range == 1_000...100_000)
        #expect(store(WiettyConfigFile.temporary()).scrollbackLines == 10_000)
    }

    @Test func aChangeIsWrittenToTheFileAndReadBackByTheNextLaunch() throws {
        let config = WiettyConfigFile.temporary()
        store(config).scrollbackLines = 25_000
        #expect(try config.read()["scrollback-lines"] == "25000")
        #expect(store(config).scrollbackLines == 25_000)
    }

    @Test func settingAValueOutsideTheRangeClampsIt() throws {
        let config = WiettyConfigFile.temporary()
        let store = store(config)
        store.scrollbackLines = 12
        #expect(store.scrollbackLines == 1_000)
        store.scrollbackLines = 5_000_000
        #expect(store.scrollbackLines == 100_000)
        #expect(try config.read()["scrollback-lines"] == "100000")
    }

    /// A hand edited file is the one place a value outside the range can come
    /// from. It is brought into the range, and a value that is not a number at all
    /// reads as the default rather than as either end.
    @Test(arguments: [("0", 1_000), ("-5", 1_000), ("999", 1_000), ("1000", 1_000),
                      ("4321", 4_321), ("100000", 100_000), ("100001", 100_000),
                      ("999999999999", 100_000), ("lots", 10_000), ("", 10_000),
                      ("10k", 10_000)])
    func aValueReadFromTheFileIsClamped(written: String, expected: Int) throws {
        let config = WiettyConfigFile.temporary()
        try config.write([("scrollback-lines", written)])
        #expect(store(config).scrollbackLines == expected)
    }

    /// A file without the key, which is every file written before the setting
    /// existed, means the default, and launching on it does not write.
    @Test func aFileWithoutTheKeyBehavesAsTheDefaultAndIsNotRewrittenByALaunch() throws {
        let config = try olderConfig()
        #expect(store(config).scrollbackLines == 10_000)
        #expect(try String(contentsOf: config.url, encoding: .utf8) == Self.olderFile)
    }

    /// And the first write after that adds the one line and moves nothing else.
    /// The store writes its scalars at their defaults too (`mcp-port` is there on
    /// a fresh install), so this one is written rather than omitted, directly
    /// under the ports.
    @Test func theFirstWriteToAnOlderFileAddsExactlyOneLine() throws {
        let config = try olderConfig()
        let fixture = SettingsFixture(config: config)
        // Any setting that makes the store write, put back where it was.
        fixture.store.remoteEnabled = false
        fixture.store.remoteEnabled = true

        // The writer gathers managed lines under its header, so the comparison is
        // of which lines there are, then of where the new one went.
        func lines(_ text: String) -> [String] {
            text.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("# Managed by") }
        }
        let before = lines(Self.olderFile)
        let after = lines(try String(contentsOf: config.url, encoding: .utf8))
        #expect(after.filter { !before.contains($0) } == ["scrollback-lines = 10000"])
        // The one line that goes is the retired setting's (`RetiredSettingTests`).
        #expect(before.filter { !after.contains($0) } == ["show-workspace-badge = false"])
        #expect(after.count == before.count)
        let index = try #require(after.firstIndex(of: "scrollback-lines = 10000"))
        #expect(after[index - 1] == "mcp-port = 7433")
        #expect(after[index + 1] == "color-background = #23292b")
    }

    /// The store owns the key and the frontend's source does not, so an omission
    /// can never be mistaken for a key nobody speaks for.
    @Test func theStoreOwnsTheKey() {
        let fixture = SettingsFixture(config: WiettyConfigFile.temporary())
        #expect(fixture.store.ownedKeys.contains(SettingsKeys.scrollbackLines))
        #expect(!fixture.preferences.ownedKeys.contains(SettingsKeys.scrollbackLines))
        #expect(SettingsKeys.fileOrder.contains(SettingsKeys.scrollbackLines))
    }
}
