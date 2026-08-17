import Testing
import Foundation
@testable import Wietty

/// The terminal colours Wietty writes into `~/.config/wietty/ghostty.cfg`, alongside
/// `desktop-notifications`. libghostty is the only thing that can apply them, so they
/// go in the file it loads rather than in Wietty's own config. Same rules as every
/// other line in that file: a colour the user did not set stays absent, one they set
/// by hand survives, and clearing a colour removes its line.
@Suite struct GhosttyOverrideFileColorTests {
    private func file() -> GhosttyOverrideFile { .temporary() }

    @Test func anAbsentFileHasNoColour() {
        #expect(file().color(for: GhosttyOverrideFile.ColorKey.background) == nil)
    }

    @Test func aWrittenColourReadsBack() throws {
        let file = file()
        try file.setColor(GhosttyOverrideFile.ColorKey.background, to: "#303446")
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.background) == "#303446")
    }

    /// Clearing a colour removes its line, so libghostty falls back to the user's own
    /// theme for it rather than a colour Wietty is still forcing.
    @Test func settingNilRemovesTheColour() throws {
        let file = file()
        try file.setColor(GhosttyOverrideFile.ColorKey.foreground, to: "#c6d0f5")
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.foreground) == "#c6d0f5")
        try file.setColor(GhosttyOverrideFile.ColorKey.foreground, to: nil)
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.foreground) == nil)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(!text.contains("foreground ="))
    }

    /// Several colours live in the file at once, and setting one leaves the others
    /// exactly as they were rather than being treated as managed lines to strip.
    @Test func settingOneColourLeavesTheOthersAlone() throws {
        let file = file()
        try file.setColor(GhosttyOverrideFile.ColorKey.background, to: "#303446")
        try file.setColor(GhosttyOverrideFile.ColorKey.cursor, to: "#f2d5cf")
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.background) == "#303446")
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.cursor) == "#f2d5cf")
    }

    /// The desktop-notifications line and a colour coexist: writing a colour must not
    /// disturb the boolean the same file already carries.
    @Test func aColourWriteLeavesDesktopNotificationsAlone() throws {
        let file = file()
        try file.setDesktopNotifications(false)
        try file.setColor(GhosttyOverrideFile.ColorKey.background, to: "#303446")
        #expect(file.desktopNotifications == false)
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.background) == "#303446")
    }

    @Test func aUsersOwnLinesSurviveAColourWrite() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "# mine\nfont-size = 15\n".write(to: file.url, atomically: true, encoding: .utf8)
        try file.setColor(GhosttyOverrideFile.ColorKey.background, to: "#303446")
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("# mine"))
        #expect(text.contains("font-size = 15"))
    }
}
