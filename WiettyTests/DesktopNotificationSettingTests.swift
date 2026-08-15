import Testing
import Foundation
@testable import Wietty

/// The file Wietty writes to override one libghostty setting.
///
/// It lives in the user's `~/.config`, which is what most of this is about: the
/// file is Wietty's to write and theirs to read and edit, so a toggle has to leave
/// everything it did not put there exactly as it found it.
@Suite struct GhosttyOverrideFileTests {
    private func file() -> GhosttyOverrideFile { .temporary() }

    /// Nothing written means no opinion, which is different from writing false.
    /// libghostty resolves the value from the user's own config in that case, and a
    /// caller that read absent as false would report notifications off for the
    /// overwhelmingly common setup of no file at all.
    @Test func anAbsentFileSaysNothing() {
        #expect(file().desktopNotifications == nil)
    }

    @Test func aWrittenValueReadsBack() throws {
        let file = file()
        try file.setDesktopNotifications(false)
        #expect(file.desktopNotifications == false)
        try file.setDesktopNotifications(true)
        #expect(file.desktopNotifications == true)
    }

    /// The first write has to create `~/.config/wietty`, which will not exist:
    /// nothing else in Wietty writes there.
    @Test func theFirstWriteCreatesTheDirectory() throws {
        let file = file()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        try file.setDesktopNotifications(true)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    /// Clearing goes back to saying nothing, rather than to saying true. Those are
    /// different: the point of clearing is to hand the decision back to the user's
    /// own config, which may well say false.
    @Test func clearingRemovesTheLineRatherThanSettingItTrue() throws {
        let file = file()
        try file.setDesktopNotifications(false)
        try file.setDesktopNotifications(nil)
        #expect(file.desktopNotifications == nil)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(!text.contains("desktop-notifications"))
    }

    /// Anything the user put in the file themselves survives, because they can and
    /// will edit it: it is in their `~/.config` and Wietty's own header invites them
    /// to look at it.
    @Test func aUsersOwnLinesSurviveAToggle() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "# mine\nfont-size = 15\ndesktop-notifications = true\ncursor-style = bar\n"
            .write(to: file.url, atomically: true, encoding: .utf8)

        try file.setDesktopNotifications(false)

        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("# mine"))
        #expect(text.contains("font-size = 15"))
        #expect(text.contains("cursor-style = bar"))
        #expect(file.desktopNotifications == false)
    }

    /// Toggling repeatedly must not grow the file. A rewrite that appended without
    /// removing would leave several lines for one key, and a blank line per pass.
    @Test func repeatedTogglesLeaveOneLineAndNoBlankRun() throws {
        let file = file()
        for value in [true, false, true, false, true] {
            try file.setDesktopNotifications(value)
        }
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.components(separatedBy: "desktop-notifications").count - 1 == 1)
        #expect(!text.contains("\n\n\n"))
        #expect(file.desktopNotifications == true)
    }

    /// A key set twice by hand resolves the way libghostty resolves it, which is
    /// last wins. Reading the first would report the opposite of what the terminal
    /// is actually running on.
    @Test func aKeySetTwiceResolvesToTheLastOne() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "desktop-notifications = true\ndesktop-notifications = false\n"
            .write(to: file.url, atomically: true, encoding: .utf8)
        #expect(file.desktopNotifications == false)
    }

    /// A commented out line is not a setting. Reading one as a value would report a
    /// setting the user deliberately turned off, and writing would then leave the
    /// comment behind while adding a second live line.
    @Test func aCommentedLineIsNotASetting() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "# desktop-notifications = false\n".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(file.desktopNotifications == nil)

        try file.setDesktopNotifications(true)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("# desktop-notifications = false"))
        #expect(file.desktopNotifications == true)
    }
}

/// The Settings tab's side of it: what the toggle reads, what it writes, and what
/// it has to say when the two configs disagree.
@MainActor
@Suite struct DesktopNotificationSettingTests {
    /// The write alone changes nothing a user can see. libghostty holds its
    /// configuration in memory, so without the reload every terminal already open
    /// keeps the old value and the toggle looks like it did nothing.
    @Test func changingItReloadsTheLiveConfig() throws {
        let host = FakeSurfaceHost()
        let setting = DesktopNotificationSetting(host: host, file: .temporary())
        setting.setEnabled(false)
        #expect(host.reloadCount == 1)
        #expect(setting.writeFailure == nil)
    }

    @Test func changingItWritesTheFile() throws {
        let file = GhosttyOverrideFile.temporary()
        let setting = DesktopNotificationSetting(host: FakeSurfaceHost(), file: file)
        setting.setEnabled(false)
        #expect(file.desktopNotifications == false)
        #expect(setting.hasOverride)
    }

    @Test func clearingTheOverrideLeavesNothingBehind() throws {
        let file = GhosttyOverrideFile.temporary()
        let setting = DesktopNotificationSetting(host: FakeSurfaceHost(), file: file)
        setting.setEnabled(false)
        setting.clearOverride()
        #expect(!setting.hasOverride)
        #expect(file.desktopNotifications == nil)
    }

    /// A write that fails must not be followed by a reload. Reloading would hand
    /// libghostty the file as it still is and report the unchanged value as the new
    /// one, so the toggle would look like it worked.
    @Test func aFailedWriteIsReportedAndNothingIsReloaded() {
        let host = FakeSurfaceHost()
        // Under a path component that is not a directory, so creating it fails.
        let unwritable = GhosttyOverrideFile(
            url: URL(fileURLWithPath: "/dev/null/wietty/ghostty.cfg"))
        let setting = DesktopNotificationSetting(host: host, file: unwritable)

        setting.setEnabled(false)

        #expect(setting.writeFailure != nil)
        #expect(host.reloadCount == 0)
    }

    /// The value the toggle shows is libghostty's, not the file's. The file is one
    /// input among several and only libghostty resolves them, so a toggle reading
    /// its own file would disagree with the terminal whenever the user's config had
    /// the last word.
    @Test func itShowsWhatLibghosttyResolvedRatherThanWhatItWrote() {
        let host = FakeSurfaceHost()
        host.desktopNotifications = (effective: false, userConfig: false)
        let setting = DesktopNotificationSetting(host: host, file: .temporary())
        #expect(!setting.isEnabled)
        #expect(!setting.hasOverride)
    }

    /// When Wietty's file wins over the user's own config, the tab says so. A switch
    /// silently contradicting a file they wrote themselves reads as Wietty having
    /// ignored it.
    @Test func itSaysWhenItIsOverridingTheUsersOwnConfig() {
        let host = FakeSurfaceHost()
        host.desktopNotifications = (effective: false, userConfig: true)
        let setting = DesktopNotificationSetting(host: host, file: .temporary())
        #expect(setting.overridesUserConfig)
        #expect(setting.userConfigValue)
    }

    @Test func itSaysNothingWhenTheTwoAgree() {
        let host = FakeSurfaceHost()
        host.desktopNotifications = (effective: true, userConfig: true)
        let setting = DesktopNotificationSetting(host: host, file: .temporary())
        #expect(!setting.overridesUserConfig)
    }

    /// The published value follows libghostty across a reload, which is what makes
    /// the switch settle where the terminal actually is. Read through a computed
    /// property instead, it would never have registered as a dependency of the view
    /// and the switch would have snapped back to its old position after every press.
    @Test func theValueFollowsTheReloadedConfig() {
        let host = FakeSurfaceHost()
        let setting = DesktopNotificationSetting(host: host, file: .temporary())
        #expect(setting.isEnabled)

        // What the real host has after its file was rewritten: a resolved value that
        // changed because the config underneath it did.
        host.desktopNotificationsAfterReload = (effective: false, userConfig: true)
        setting.setEnabled(false)

        #expect(!setting.isEnabled)
        #expect(setting.overridesUserConfig)
    }

    /// A launch with no libghostty still draws the tab. Reporting libghostty's own
    /// default rather than false keeps it from claiming notifications are turned off
    /// when the truth is there is no terminal to turn them off for.
    @Test func withNoHostItReportsTheDefault() {
        let setting = DesktopNotificationSetting(host: nil, file: .temporary())
        #expect(setting.isEnabled)
        #expect(!setting.overridesUserConfig)
    }
}
