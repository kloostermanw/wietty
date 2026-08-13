import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// What the Local section's header shows, and whether the section is collapsed.
///
/// A rule rather than a line inside `body`, so the case that matters most (a stored
/// collapse that no chevron can undo) is asserted in CI rather than only reachable
/// by collapsing the section, removing every connection, and relaunching.
@Suite struct LocalSectionHeaderTests {
    /// One section in the sidebar means nothing to tell it apart from, so the title
    /// and its chevron are noise.
    @Test func withoutRemoteConnectionsTheHeaderHasNoTitle() {
        let header = LocalSectionHeader.resolve(hasRemoteConnections: false, storedCollapsed: false)
        #expect(header.title == nil)
    }

    /// A second section on screen is what the word Local is for.
    @Test func withRemoteConnectionsTheHeaderIsTitled() {
        let header = LocalSectionHeader.resolve(hasRemoteConnections: true, storedCollapsed: false)
        #expect(header.title == "Local")
    }

    /// The one that would strand the user: no title means no chevron, so a stored
    /// collapse has to be ignored or the workspace list is invisible with nothing on
    /// screen to bring it back.
    @Test func aStoredCollapseIsIgnoredWithoutAHeaderToUndoIt() {
        let header = LocalSectionHeader.resolve(hasRemoteConnections: false, storedCollapsed: true)
        #expect(header.collapsed == false)
    }

    /// Ignored, not cleared. Adding a connection puts the chevron back and the
    /// section is collapsed again, which is what the user last asked for.
    @Test func aStoredCollapseAppliesOnceThereIsAChevron() {
        let header = LocalSectionHeader.resolve(hasRemoteConnections: true, storedCollapsed: true)
        #expect(header.collapsed == true)
        #expect(header.title == "Local")
    }

    @Test func anExpandedSectionStaysExpandedEitherWay() {
        #expect(LocalSectionHeader.resolve(hasRemoteConnections: true,
                                           storedCollapsed: false).collapsed == false)
        #expect(LocalSectionHeader.resolve(hasRemoteConnections: false,
                                           storedCollapsed: false).collapsed == false)
    }

    /// A titleless header still occupies its row. The buttons are what the row is
    /// really for, and a header that shrank to nothing when the title went would move
    /// the whole workspace list up under the window's top edge.
    ///
    /// Measured rather than eyeballed, because the answer is SwiftUI's: the same
    /// hosting measurement `LocalTerminalViewTests` uses for the pane's height.
    @MainActor
    @Test func aTitlelessHeaderKeepsTheRowItsButtonsNeed() {
        let buttons = ContentView.localSectionButtons(refresh: {}, add: {})
        let titled = SidebarSectionHeaderView(title: "Local", collapsed: false,
                                              onToggle: {}, buttons: buttons)
        let untitled = SidebarSectionHeaderView(title: nil, collapsed: false,
                                                onToggle: {}, buttons: buttons)
        let offered = NSSize(width: 320, height: 760)
        let titledHeight = NSHostingController(rootView: titled).sizeThatFits(in: offered).height
        let untitledHeight = NSHostingController(rootView: untitled).sizeThatFits(in: offered).height
        #expect(untitledHeight == titledHeight)
        #expect(untitledHeight > 0)
    }
}
