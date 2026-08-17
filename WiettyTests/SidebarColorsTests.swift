import Testing
import Foundation
import SwiftUI
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
    }

    @Test func readsHexValuesFromConfig() throws {
        let colours = SidebarColors(from: [
            "color-background": "#303446",
            "color-active-terminal-row-background": "#292b34",
        ])
        #expect(ColorHex.string(from: try #require(colours.background)) == "#303446")
        #expect(ColorHex.string(from: try #require(colours.activeTerminalRowBackground)) == "#292b34")
        #expect(colours.foreground == nil)
    }

    @Test func emitsOnlyTheColoursThatAreSet() {
        var colours = SidebarColors()
        colours.foreground = ColorHex.color(from: "#c6d0f5")
        let keys = colours.pairs.map(\.key)
        #expect(keys == ["color-foreground"])
        #expect(colours.pairs.first?.value == "#c6d0f5")
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
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        store.sidebarColors.background = ColorHex.color(from: "#303446")
        store.sidebarColors.activeTerminalRowBackground = ColorHex.color(from: "#292b34")

        let values = try config.read()
        #expect(values["color-background"] == "#303446")
        #expect(values["color-active-terminal-row-background"] == "#292b34")
    }

    @Test func coloursRoundTripAcrossInstances() throws {
        let defaults = makeDefaults()
        let config = WiettyConfigFile.temporary()
        let store1 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        store1.sidebarColors.foreground = ColorHex.color(from: "#c6d0f5")
        let store2 = ProjectStore(defaults: defaults, config: config, service: FakeTerminalService())
        #expect(ColorHex.string(from: try #require(store2.sidebarColors.foreground)) == "#c6d0f5")
    }

    /// Clearing a colour deletes its line, so the sidebar goes back to the default
    /// rather than carrying a stale override.
    @Test func clearingAColourRemovesItsLine() throws {
        let config = WiettyConfigFile.temporary()
        let store = ProjectStore(defaults: makeDefaults(), config: config, service: FakeTerminalService())
        store.sidebarColors.background = ColorHex.color(from: "#303446")
        #expect(try config.read()["color-background"] == "#303446")
        store.sidebarColors.background = nil
        #expect(try config.read()["color-background"] == nil)
    }

    @Test func aFreshStoreHasNoColourOverrides() {
        let store = ProjectStore(defaults: makeDefaults(), config: WiettyConfigFile.temporary(),
                                 service: FakeTerminalService())
        #expect(store.sidebarColors == SidebarColors())
    }
}
