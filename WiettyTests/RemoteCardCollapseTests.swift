import Testing
import Foundation
@testable import Wietty

/// The remote sidebar's per workspace card collapse: which key it is stored
/// under, and that a card nobody has touched starts collapsed.
@MainActor
@Suite struct RemoteCardCollapseTests {
    private let connectionA = UUID()
    private let connectionB = UUID()
    private let workspace = UUID()

    @Test func keyIsScopedToConnectionAndWorkspace() {
        let a = RemoteSectionView.cardKey(connectionId: connectionA, workspaceId: workspace)
        let b = RemoteSectionView.cardKey(connectionId: connectionB, workspaceId: workspace)
        #expect(a != b)
        #expect(a.contains(connectionA.uuidString))
        #expect(a.contains(workspace.uuidString))
    }

    @Test func untouchedCardStartsCollapsed() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let state = SectionCollapseState(defaults: defaults)
        let key = RemoteSectionView.cardKey(connectionId: connectionA, workspaceId: workspace)
        #expect(state.isCollapsed(key, default: true) == true)
    }

    @Test func expandingSurvivesRelaunch() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let key = RemoteSectionView.cardKey(connectionId: connectionA, workspaceId: workspace)
        SectionCollapseState(defaults: defaults).setCollapsed(key, false)
        #expect(SectionCollapseState(defaults: defaults).isCollapsed(key, default: true) == false)
    }

    /// Two connections serving a workspace with the same id (the same folder
    /// cloned onto two Macs) keep separate collapse flags.
    @Test func connectionsDoNotShareOneFlag() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let state = SectionCollapseState(defaults: defaults)
        state.setCollapsed(RemoteSectionView.cardKey(connectionId: connectionA, workspaceId: workspace), false)
        #expect(state.isCollapsed(RemoteSectionView.cardKey(connectionId: connectionB,
                                                           workspaceId: workspace),
                                 default: true) == true)
    }
}
