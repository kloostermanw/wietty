import Testing
import AppKit
import SwiftUI
import WiettyShared
@testable import Wietty

/// What Settings has to survive now that it is the pane rather than a window of its
/// own.
///
/// A window sized itself to the form. The pane's width is a divider the user drags
/// and its height is the window's, so the panel has to fill what it is offered and
/// carry the same floor as everything else the pane can hold. Measured through
/// `RightTerminalView` rather than `SettingsView` directly, because the branch that
/// puts the panel in the pane is part of what is being asserted, and measured with
/// `NSHostingController` the way `LocalTerminalViewTests` measures the pane, which
/// needs neither a window nor a Metal device.
@MainActor
@Suite struct SettingsPaneTests {
    private func pane(_ selection: PaneSelection) -> RightTerminalView {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connections = RemoteConnectionsStore(defaults: defaults)
        return RightTerminalView(
            store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
            stack: GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true"),
            remoteConnections: connections,
            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
            selection: selection)
    }

    private func sizeOffered<V: View>(_ view: V, _ size: NSSize) -> NSSize {
        NSHostingController(rootView: view).sizeThatFits(in: size)
    }

    /// The panel takes the width it is given. It was a fixed 380 points as a window,
    /// which in a column the user drags to any width would leave dead space beside
    /// it.
    @Test func settingsFillsTheWidthItIsOffered() {
        #expect(sizeOffered(pane(.settings), NSSize(width: 900, height: 800)).width == 900)
    }

    /// And the height, by scrolling rather than asking for the height its form wants.
    /// The window's minimum height is built from the pane's floor, so a panel that
    /// demanded its content height would resize the window every time it is opened.
    @Test func settingsScrollsRatherThanDemandingItsContentHeight() {
        #expect(sizeOffered(pane(.settings), NSSize(width: 900, height: 300)).height == 300)
    }

    /// The same floor the other things in the pane carry, so what is on screen cannot
    /// change how small the window can get.
    @Test func settingsKeepsThePaneMinimumInAWindowSmallerThanIt() {
        let size = sizeOffered(pane(.settings), NSSize(width: 100, height: 100))
        #expect(Double(size.width) == SidebarWidth.paneMinimum)
        #expect(Double(size.height) == SidebarWidth.paneMinimumHeight)
    }

    /// The bar above the pane is the way in, and the only one on screen: the app menu
    /// and ⌘, are the other two and neither is visible in a window with no title bar.
    @Test func theBarOffersSettingsAndNothingElse() {
        let buttons = NavBarView.trailingButtons(openSettings: {})
        #expect(buttons.map(\.system) == ["gearshape"])
    }

    /// Forces a real render pass over the whole panel, so a construction or wiring
    /// crash anywhere in it surfaces here rather than the first time it is opened.
    @Test func thePaneRendersSettings() {
        let renderer = ImageRenderer(content: pane(.settings).frame(width: 600, height: 800))
        #expect(renderer.nsImage != nil)
    }
}
