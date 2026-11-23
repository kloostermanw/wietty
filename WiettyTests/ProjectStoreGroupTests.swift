import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Groups are a machine-local list the store carries, like the agents: the set of
/// groups, which workspace belongs to which, and which group is active all persist to
/// `~/.config/wietty/config` and come back on the next launch.
@Suite @MainActor struct ProjectStoreGroupTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = TestScratch.root
            .appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ defaults: UserDefaults) -> ProjectStore {
        ProjectStore(defaults: defaults, service: FakeTerminalService())
    }

    /// The active group now belongs to `UIPreferences`, which resolves it against the
    /// groups the store holds, so these build the pair the app builds.
    private func fixture(_ defaults: UserDefaults) -> SettingsFixture {
        SettingsFixture(defaults: defaults)
    }

    /// A fresh install has no groups and no active group: the sidebar shows every
    /// workspace until the user makes a group and picks it.
    @Test func aFreshStoreHasNoGroupsAndNoSelection() {
        let fixture = fixture(makeDefaults())
        #expect(fixture.store.groups.isEmpty)
        #expect(fixture.preferences.selectedGroupId == nil)
    }

    @Test func anAddedGroupSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addGroup(WorkspaceGroup(name: "Work"))
        #expect(store(defaults).groups.map(\.name) == ["Work"])
    }

    /// Dragging a group to reorder the list is a real reorder that survives a relaunch.
    @Test func movingAGroupReordersAndPersists() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addGroup(WorkspaceGroup(name: "Work"))
        first.addGroup(WorkspaceGroup(name: "Private"))
        first.addGroup(WorkspaceGroup(name: "Side"))
        // Work, Private, Side -> move Side (index 2) to the front.
        first.moveGroup(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(first.groups.map(\.name) == ["Side", "Work", "Private"])
        #expect(store(defaults).groups.map(\.name) == ["Side", "Work", "Private"])
    }

    @Test func updatingAGroupRenamesTheOneWithThatId() {
        let store = store(makeDefaults())
        store.addGroup(WorkspaceGroup(name: "Wrok"))
        var group = store.groups[0]
        group.name = "Work"
        store.updateGroup(group)
        #expect(store.groups.map(\.name) == ["Work"])
    }

    /// An update for a group deleted in the meantime adds nothing back: the Settings
    /// row is on screen while the list can change under it.
    @Test func updatingAnUnknownGroupChangesNothing() {
        let store = store(makeDefaults())
        store.updateGroup(WorkspaceGroup(name: "Ghost"))
        #expect(store.groups.isEmpty)
    }

    @Test func assigningAWorkspaceToAGroupSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addGroup(WorkspaceGroup(name: "Work"))
        first.addProject(url: makeTempFolder(named: "alpha"))
        let group = first.groups[0]
        first.assignGroup(first.projects[0], to: group.id)

        let second = store(defaults)
        #expect(second.projects.first?.groupId == group.id)
    }

    @Test func assigningToNilClearsAWorkspacesGroup() {
        let store = store(makeDefaults())
        store.addGroup(WorkspaceGroup(name: "Work"))
        store.addProject(url: makeTempFolder(named: "alpha"))
        store.assignGroup(store.projects[0], to: store.groups[0].id)
        store.assignGroup(store.projects[0], to: nil)
        #expect(store.projects[0].groupId == nil)
    }

    /// Deleting a group unfiles every workspace that was in it rather than leaving a
    /// dangling id that no group answers to.
    @Test func removingAGroupClearsItsAssignments() {
        let store = store(makeDefaults())
        store.addGroup(WorkspaceGroup(name: "Work"))
        store.addProject(url: makeTempFolder(named: "alpha"))
        let id = store.groups[0].id
        store.assignGroup(store.projects[0], to: id)
        store.removeGroup(id: id)
        #expect(store.groups.isEmpty)
        #expect(store.projects[0].groupId == nil)
    }

    /// A removed group is gone from a reloaded store, not just from memory: the list
    /// is written back with its trailing `group.N.*` lines dropped (the `groupPrefix`
    /// in `SettingsKeys.prefixes`), so a deleted group cannot resurface on relaunch.
    @Test func aRemovedGroupDoesNotSurviveARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addGroup(WorkspaceGroup(name: "Work"))
        first.addGroup(WorkspaceGroup(name: "Private"))
        first.removeGroup(id: first.groups[0].id)

        #expect(store(defaults).groups.map(\.name) == ["Private"])
    }

    /// Removing the active group puts the sidebar back to "All". The store no longer
    /// clears the selection by hand: it belongs to `UIPreferences`, which resolves it
    /// against the groups that exist, so an id whose group is gone already reads nil.
    @Test func removingTheActiveGroupClearsTheSelection() {
        let fixture = fixture(makeDefaults())
        fixture.store.addGroup(WorkspaceGroup(name: "Work"))
        let id = fixture.store.groups[0].id
        fixture.preferences.selectedGroupId = id
        fixture.store.removeGroup(id: id)
        #expect(fixture.preferences.selectedGroupId == nil)
    }

    @Test func theActiveGroupSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = fixture(defaults)
        first.store.addGroup(WorkspaceGroup(name: "Work"))
        let id = first.store.groups[0].id
        first.preferences.selectedGroupId = id
        #expect(fixture(defaults).preferences.selectedGroupId == id)
    }

    /// A stored selection that no group answers to (a hand-edited file, or a group
    /// removed by an older build) falls back to "All" rather than filtering every
    /// workspace away against a group that is gone.
    @Test func aSelectionForAMissingGroupFallsBackToAll() {
        let defaults = makeDefaults()
        let first = fixture(defaults)
        first.preferences.selectedGroupId = UUID()  // no group has this id
        #expect(fixture(defaults).preferences.selectedGroupId == nil)
    }
}
