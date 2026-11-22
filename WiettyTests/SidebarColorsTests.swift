import Foundation
import SwiftUI
import Testing
import WiettyCore
@testable import Wietty

/// The six colours the sidebar can be given. Each is optional: nil is "leave the
/// default", which is an untouched install and what deleting a line in the config
/// file returns to. These assert the mapping onto config keys, both directions.
@Suite struct SidebarColorsValueTests {
    @Test func aFreshValueHasNoOverrides() {
        let colours = SidebarColors()
        #expect(colours.background == nil)
        #expect(colours.foreground == nil)
        #expect(colours.activeWorkspaceBackground == nil)
        #expect(colours.activeWorkspaceForeground == nil)
        #expect(colours.activeTerminalRowBackground == nil)
        #expect(colours.activeTerminalRowForeground == nil)
        #expect(colours.pillBackground == nil)
        #expect(colours.pillForeground == nil)
    }

    @Test func readsHexValuesFromConfig() throws {
        let colours = SidebarColors(from: [
            "color-background": "#303446",
            "color-active-terminal-row-background": "#292b34",
            "color-pill-background": "#ca9ee6",
            "color-pill-foreground": "#232634",
        ])
        #expect(ColorHex.string(from: try #require(colours.background)) == "#303446")
        #expect(ColorHex.string(from: try #require(colours.activeTerminalRowBackground)) == "#292b34")
        #expect(ColorHex.string(from: try #require(colours.pillBackground)) == "#ca9ee6")
        #expect(ColorHex.string(from: try #require(colours.pillForeground)) == "#232634")
        #expect(colours.foreground == nil)
    }

    @Test func emitsOnlyTheColoursThatAreSet() {
        var colours = SidebarColors()
        colours.foreground = ColorHex.color(from: "#c6d0f5")
        let keys = colours.pairs.map(\.key)
        #expect(keys == ["color-foreground"])
        #expect(colours.pairs.first?.value == "#c6d0f5")
    }

    @Test func emitsThePillColoursThatAreSet() {
        var colours = SidebarColors()
        colours.pillBackground = ColorHex.color(from: "#ca9ee6")
        colours.pillForeground = ColorHex.color(from: "#232634")
        let pairs = Dictionary(uniqueKeysWithValues: colours.pairs.map { ($0.key, $0.value) })
        #expect(pairs["color-pill-background"] == "#ca9ee6")
        #expect(pairs["color-pill-foreground"] == "#232634")
        #expect(pairs.count == 2)
    }
}

/// The colours persist through `ProjectStore` into `~/.config/wietty/config` and
/// back, the same way every other scalar setting does.
@MainActor
@Suite struct SidebarColorsStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    @Test func coloursAreWrittenToTheConfigFile() throws {
        let config = WiettyConfigFile.temporary()
        let storeFx = SettingsFixture(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        let store = storeFx.store
        storeFx.preferences.sidebarColors.background = ColorHex.color(from: "#303446")
        storeFx.preferences.sidebarColors.activeTerminalRowBackground = ColorHex.color(from: "#292b34")

        let values = try config.read()
        #expect(values["color-background"] == "#303446")
        #expect(values["color-active-terminal-row-background"] == "#292b34")
    }

    @Test func coloursRoundTripAcrossInstances() throws {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store1Fx = SettingsFixture(defaults: defaults, config: config, service: FakeTerminalService())
        let store1 = store1Fx.store
        store1Fx.preferences.sidebarColors.foreground = ColorHex.color(from: "#c6d0f5")
        let store2Fx = SettingsFixture(defaults: defaults, config: config, service: FakeTerminalService())
        let store2 = store2Fx.store
        #expect(ColorHex.string(from: try #require(store2Fx.preferences.sidebarColors.foreground)) == "#c6d0f5")
    }

    /// Clearing a colour deletes its line, so the sidebar goes back to the default
    /// rather than carrying a stale override.
    @Test func clearingAColourRemovesItsLine() throws {
        let config = WiettyConfigFile.temporary()
        let storeFx = SettingsFixture(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        let store = storeFx.store
        storeFx.preferences.sidebarColors.background = ColorHex.color(from: "#303446")
        #expect(try config.read()["color-background"] == "#303446")
        storeFx.preferences.sidebarColors.background = nil
        #expect(try config.read()["color-background"] == nil)
    }

    @Test func aFreshStoreHasNoColourOverrides() {
        let storeFx = SettingsFixture(defaults: makeDefaults(), config: WiettyConfigFile.temporary())
        #expect(storeFx.preferences.sidebarColors == SidebarColors())
    }

    @Test func pillColoursRoundTripAcrossInstances() throws {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store1Fx = SettingsFixture(defaults: defaults, config: config, service: FakeTerminalService())
        let store1 = store1Fx.store
        store1Fx.preferences.sidebarColors.pillBackground = ColorHex.color(from: "#ca9ee6")
        store1Fx.preferences.sidebarColors.pillForeground = ColorHex.color(from: "#232634")
        let store2Fx = SettingsFixture(defaults: defaults, config: config, service: FakeTerminalService())
        let store2 = store2Fx.store
        #expect(ColorHex.string(from: try #require(store2Fx.preferences.sidebarColors.pillBackground)) == "#ca9ee6")
        #expect(ColorHex.string(from: try #require(store2Fx.preferences.sidebarColors.pillForeground)) == "#232634")
    }
}
