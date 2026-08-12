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
    /// A pane over an empty store: remote access off, no connections.
    private func pane(_ selection: PaneSelection) -> RightTerminalView {
        pane(selection, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func pane(_ selection: PaneSelection, defaults: UserDefaults) -> RightTerminalView {
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

    /// And the height, by accepting an offer smaller than its content rather than
    /// asking for the height its form wants. The window's minimum height is built from
    /// the pane's floor, so a panel that demanded its content height would resize the
    /// window every time it is opened.
    ///
    /// The unbounded measurement is what makes the equality mean something: it shows
    /// the content really is taller than the offer, so `== 300` is the panel yielding
    /// rather than the form happening to fit. It still cannot tell scrolling from
    /// clipping, which is a manual check.
    @Test func settingsYieldsToAHeightSmallerThanItsContent() {
        let unbounded = sizeOffered(pane(.settings),
                                    NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude))
        #expect(unbounded.height > 300)
        #expect(sizeOffered(pane(.settings), NSSize(width: 900, height: 300)).height == 300)
    }

    /// The same floor the other things in the pane carry, so what is on screen cannot
    /// change how small the window can get.
    @Test func settingsKeepsThePaneMinimumInAWindowSmallerThanIt() {
        let size = sizeOffered(pane(.settings), NSSize(width: 100, height: 100))
        #expect(Double(size.width) == SidebarWidth.paneMinimum)
        #expect(Double(size.height) == SidebarWidth.paneMinimumHeight)
    }

    /// The bar above the pane is the way in that is inside the window. The app menu's
    /// item and ⌘, are the other two, and the window has no title bar of its own.
    ///
    /// The help text is asserted too: the gear is icon only, so that string is the
    /// whole of its name in the tooltip and in `accessibilityLabel`.
    @Test func theBarOffersSettingsAndNothingElse() {
        let buttons = NavBarView.trailingButtons(openSettings: {})
        #expect(buttons.map(\.system) == ["gearshape"])
        #expect(buttons.map(\.help) == ["Settings"])
    }

    /// The spec's id has to survive a redraw. A fresh `UUID` per pass, which is what
    /// this was, gives `ForEach` a new identity every time the bar redraws, so the
    /// button is rebuilt rather than updated and a redraw between mouse down and mouse
    /// up drops the click. The bar redraws on every selection change and every git poll.
    @Test func aButtonSpecKeepsItsIdentityAcrossRebuilds() {
        let first = NavBarView.trailingButtons(openSettings: {})
        let second = NavBarView.trailingButtons(openSettings: {})
        #expect(first.map(\.id) == second.map(\.id))
    }

    /// Forces a real render pass over the whole panel, so a construction or wiring
    /// crash anywhere in it surfaces here rather than the first time it is opened.
    @Test func thePaneRendersSettings() {
        let renderer = ImageRenderer(content: pane(.settings).frame(width: 600, height: 800))
        #expect(renderer.nsImage != nil)
    }

    /// The same, for the two sub-trees an empty store never reaches: the URL and QR
    /// block behind `remoteEnabled`, and `RemoteConnectionRow`. Both draw inside the
    /// main window now, so a crash in either takes the window rather than a secondary
    /// one. `LocalNetwork.primaryIPv4()` returning nil on a machine with no interface
    /// picks the other branch of that block, which is also worth passing through.
    @Test func thePaneRendersSettingsWithRemoteAccessOnAndAConnection() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connections = RemoteConnectionsStore(defaults: defaults)
        connections.add(RemoteConnection(id: UUID(), name: "Office Mac",
                                         host: "192.168.1.20", port: 7434, token: "t"))
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.remoteEnabled = true
        let view = RightTerminalView(
            store: store,
            stack: GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true"),
            remoteConnections: connections,
            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
            selection: .settings)
        let renderer = ImageRenderer(content: view.frame(width: 600, height: 1200))
        #expect(renderer.nsImage != nil)
    }

    /// The app menu's item, which is the one part of the way in that no pure type can
    /// answer for.
    ///
    /// Possible only because `WiettyTests` is hosted by the app itself (`TEST_HOST`),
    /// so the real `WiettyApp` has launched and SwiftUI has installed its menu before
    /// this runs. It pins the three things deleting the `Settings` scene put at risk:
    /// that the item survived `CommandGroup(replacing: .appSettings)`, that it kept ⌘,,
    /// and that there is exactly one of it, so re-adding a `Settings` scene later would
    /// fail here rather than double bind the shortcut. It cannot press the item: the
    /// test has no handle on the app's own `PaneRouter`.
    @Test func theAppMenuOffersSettingsOnCommandComma() {
        let items = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.title == "Settings…" } ?? []
        #expect(items.count == 1)
        #expect(items.first?.keyEquivalent == ",")
        #expect(items.first?.keyEquivalentModifierMask == .command)
    }

    /// The bar itself, which this change gave a `Button`, a `ForEach` and a
    /// conditional `foregroundStyle`. Both states, because the tint is the branch.
    @Test func theBarRendersWithAndWithoutTheSettingsPanelUp() {
        for selection in [PaneSelection.settings, .none] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let connections = RemoteConnectionsStore(defaults: defaults)
            let bar = NavBarView(
                store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
                remoteWorkspaces: RemoteWorkspacesController(connections: connections),
                selection: selection,
                onOpenSettings: {})
            let renderer = ImageRenderer(content: bar.frame(width: 600))
            #expect(renderer.nsImage != nil)
        }
    }
}
