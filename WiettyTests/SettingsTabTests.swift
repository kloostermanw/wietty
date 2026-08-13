import Testing
@testable import Wietty

/// Which tabs the settings panel offers and in what order, asserted here rather
/// than only visible by opening the panel. Same reason `NavBarView.trailingButtons`
/// is a static function: the set of things a bar shows is a fact about the app, and
/// a fact about the app belongs in CI.
@Suite struct SettingsTabTests {
    @Test func theFiveTabsAreOfferedInOrder() {
        #expect(SettingsTab.allCases == [.general, .notifications, .agents, .remote, .mcp])
    }

    @Test func everyTabIsTitled() {
        #expect(SettingsTab.allCases.map(\.title)
            == ["General", "Notifications", "Agents", "Remote", "MCP"])
    }

    /// The panel opens here. Asserted against `.general` by name rather than against
    /// `allCases.first`, which it currently also is: the two would otherwise agree by
    /// construction, and reordering the segments could move where the panel lands
    /// without failing anything.
    @Test func theDefaultTabIsGeneral() {
        #expect(SettingsTab.default == .general)
    }

}
