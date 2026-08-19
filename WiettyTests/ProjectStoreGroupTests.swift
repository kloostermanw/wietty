import Testing
import Foundation
@testable import Wietty

/// Groups are a machine-local list the store carries, like the agents: the set of
/// groups, which workspace belongs to which, and which group is active all persist to
/// `~/.config/wietty/config` and come back on the next launch.
@Suite @MainActor struct ProjectStoreGroupTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ defaults: UserDefaults) -> ProjectStore {
        ProjectStore(defaults: defaults, service: FakeTerminalService())
    }

    /// A fresh install has no groups and no active group: the sidebar shows every
    /// workspace until the user makes a group and picks it.
    @Test func aFreshStoreHasNoGroupsAndNoSelection() {
        let store = store(makeDefaults())
        #expect(store.groups.isEmpty)
        #expect(store.selectedGroupId == nil)
    }

    @Test func anAddedGroupSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addGroup(WorkspaceGroup(name: "Work"))
        #expect(store(defaults).groups.map(\.name) == ["Work"])
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

    @Test func removingTheActiveGroupClearsTheSelection() {
        let store = store(makeDefaults())
        store.addGroup(WorkspaceGroup(name: "Work"))
        let id = store.groups[0].id
        store.selectedGroupId = id
        store.removeGroup(id: id)
        #expect(store.selectedGroupId == nil)
    }

    @Test func theActiveGroupSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.addGroup(WorkspaceGroup(name: "Work"))
        let id = first.groups[0].id
        first.selectedGroupId = id
        #expect(store(defaults).selectedGroupId == id)
    }

    /// A stored selection that no group answers to (a hand-edited file, or a group
    /// removed by an older build) falls back to "All" rather than filtering every
    /// workspace away against a group that is gone.
    @Test func aSelectionForAMissingGroupFallsBackToAll() {
        let defaults = makeDefaults()
        let first = store(defaults)
        first.selectedGroupId = UUID()  // no group has this id
        #expect(store(defaults).selectedGroupId == nil)
    }
}
