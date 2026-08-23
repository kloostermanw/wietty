import Testing
import SwiftUI
@testable import Wietty

/// The colours the Issue/PR pills draw. Each is optional on `SidebarColors`: nil is
/// "leave the default", which keeps the accent-derived look an untouched install has,
/// and a set colour is used as-is. The resolution is a pure function so both the
/// fallback and the override are asserted in CI rather than only visible on screen.
@Suite struct IssuePRPillColorTests {
    @Test func anUnsetBackgroundKeepsTheAccentDefault() {
        let fill = IssuePRPillColors.fill(override: nil)
        #expect(fill == Color.accentColor.opacity(0.22))
    }

    @Test func aSetBackgroundIsUsedAsIs() throws {
        let override = try #require(ColorHex.color(from: "#ca9ee6"))
        #expect(IssuePRPillColors.fill(override: override) == override)
    }

    @Test func anUnsetForegroundKeepsTheTintDefault() {
        #expect(IssuePRPillColors.text(override: nil) == Color.accentColor)
    }

    @Test func aSetForegroundIsUsedAsIs() throws {
        let override = try #require(ColorHex.color(from: "#232634"))
        #expect(IssuePRPillColors.text(override: override) == override)
    }
}
