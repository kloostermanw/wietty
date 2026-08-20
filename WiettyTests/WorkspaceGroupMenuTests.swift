import Testing
import Foundation
@testable import Wietty

/// The Group menu's shape and the sidebar filter are facts about the app, so they
/// live in a pure type asserted in CI rather than only being checkable by opening the
/// menu, the same split `WorkspaceMenu` uses.
@Suite struct WorkspaceGroupMenuTests {
    private func project(_ name: String, group: UUID?) -> Project {
        Project(url: URL(fileURLWithPath: "/tmp/\(name)"), groupId: group)
    }

    private let work = WorkspaceGroup(name: "Work")
    private let priv = WorkspaceGroup(name: "Private")

    /// "All" leads the menu and is the checked one when no group is active.
    @Test func allLeadsAndIsSelectedWhenNothingIsActive() {
        let items = WorkspaceGroupMenu.items(groups: [work, priv], selected: nil)
        #expect(items.first?.id == nil)
        #expect(items.first?.title == "All")
        #expect(items.first?.isSelected == true)
    }

    /// Each group follows "All" in list order, and the active one is the only checked
    /// entry.
    @Test func groupsFollowAllInOrderWithTheActiveOneChecked() {
        let items = WorkspaceGroupMenu.items(groups: [work, priv], selected: priv.id)
        #expect(items.map(\.title) == ["All", "Work", "Private"])
        #expect(items.filter(\.isSelected).map(\.id) == [priv.id])
    }

    @Test func aFilterOfNilShowsEveryWorkspace() {
        let projects = [project("a", group: work.id), project("b", group: nil)]
        #expect(WorkspaceGroupMenu.visible(projects, selected: nil).count == 2)
    }

    /// A selected group shows only its members. An unassigned workspace is not one of
    /// them, so it shows only under "All".
    @Test func aSelectedGroupShowsOnlyItsMembers() {
        let inWork = project("a", group: work.id)
        let unassigned = project("b", group: nil)
        let inPrivate = project("c", group: priv.id)
        let visible = WorkspaceGroupMenu.visible([inWork, unassigned, inPrivate], selected: work.id)
        #expect(visible.map(\.id) == [inWork.id])
    }
}
