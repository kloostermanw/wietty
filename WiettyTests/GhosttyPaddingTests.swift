import Foundation
import Testing
@testable import Wietty

/// The configured window padding, read from the files the host's configuration is
/// built from, because `ghostty_config_get` does not expose it.
@Suite struct GhosttyPaddingTests {
    private func padding(_ lines: String...) -> GhosttyPadding {
        var padding = GhosttyPadding.ghosttyDefault
        for line in lines { padding.apply(line: line) }
        return padding
    }

    private func file(_ contents: String) throws -> URL {
        let url = TestScratch.root.appendingPathComponent("wietty-padding-\(UUID().uuidString).cfg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func nothingConfiguredIsGhosttysDefault() {
        #expect(padding() == GhosttyPadding(left: 2, right: 2, top: 2, bottom: 2))
        #expect(padding().pixels(scale: 1) == (x: 4, y: 4))
        #expect(padding().pixels(scale: 2) == (x: 8, y: 8))
    }

    /// One value sets both sides, so the total is twice it.
    @Test func oneValueSetsBothSides() {
        let padded = padding("window-padding-x = 13", "window-padding-y = 7")
        #expect(padded == GhosttyPadding(left: 13, right: 13, top: 7, bottom: 7))
        #expect(padded.pixels(scale: 1) == (x: 26, y: 14))
        #expect(padded.pixels(scale: 2) == (x: 52, y: 28))
    }

    /// Two values are left and right (or top and bottom); the total is their sum.
    @Test func twoValuesSetEachSide() {
        let padded = padding("window-padding-x = 2,4", "window-padding-y=3, 8")
        #expect(padded == GhosttyPadding(left: 2, right: 4, top: 3, bottom: 8))
        #expect(padded.pixels(scale: 1) == (x: 6, y: 11))
        #expect(padded.pixels(scale: 2) == (x: 12, y: 22))
    }

    /// Each side is rounded down on its own, as libghostty does, which only shows
    /// at a scale that is not whole.
    @Test func eachSideIsRoundedDownOnItsOwn() {
        #expect(padding("window-padding-x = 3", "window-padding-y = 1,2").pixels(scale: 1.5) == (x: 8, y: 4))
    }

    @Test func theLastLineWins() {
        #expect(padding("window-padding-x = 9", "window-padding-x = 5").left == 5)
    }

    /// An empty value resets the key, as in Ghostty.
    @Test func anEmptyValueResetsToTheDefault() {
        #expect(padding("window-padding-x = 9", "window-padding-x =") == .ghosttyDefault)
    }

    /// A line Ghostty would reject changes nothing, as it changes nothing there.
    @Test func aRejectedValueLeavesTheKeyAsItWas() {
        let before = padding("window-padding-x = 9")
        for line in ["window-padding-x = -1", "window-padding-x = 1.5", "window-padding-x = a",
                     "window-padding-x = 1,2,3", "window-padding-x = ,4"] {
            var padded = before
            padded.apply(line: line)
            #expect(padded == before, "\(line)")
        }
    }

    @Test func commentsQuotesAndOtherKeys() {
        #expect(padding("# window-padding-x = 9") == .ghosttyDefault)
        #expect(padding("window-padding-balance = true", "background = #000000") == .ghosttyDefault)
        #expect(padding("window-padding-x = \"6\"").left == 6)
        #expect(padding("  window-padding-y   =   11  ").top == 11)
    }

    /// Files are read in order, a later one overriding an earlier one, and a file
    /// that does not exist sets nothing.
    @Test func laterFilesOverrideEarlierOnes() throws {
        let first = try file("window-padding-x = 9\nwindow-padding-y = 4\n")
        let second = try file("# Wietty\nwindow-padding-x = 5,6\n")
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        let missing = TestScratch.root.appendingPathComponent("absent-\(UUID().uuidString).cfg")
        #expect(GhosttyPadding.resolve(files: [first, missing, second])
                == GhosttyPadding(left: 5, right: 6, top: 4, bottom: 4))
    }

    /// The files libghostty reads by default, in its order, honouring
    /// `XDG_CONFIG_HOME`.
    @Test func theDefaultFilesAreLibghosttysInItsOrder() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(GhosttyPadding.defaultFiles(environment: [:], home: home).map(\.path) == [
            "/Users/someone/.config/ghostty/config",
            "/Users/someone/.config/ghostty/config.ghostty",
            "/Users/someone/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/someone/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(GhosttyPadding.defaultFiles(environment: ["XDG_CONFIG_HOME": "/elsewhere"], home: home)
            .first?.path == "/elsewhere/ghostty/config")
    }
}
