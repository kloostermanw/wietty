import Testing
import Foundation
@testable import Wietty

/// One group a workspace can belong to: a name the user typed and a stable id the
/// assignment and the active-group selection point at. A value type, like
/// `AgentDefinition`, so the set of groups is a fact the store carries rather than a
/// view owning it.
@Suite struct WorkspaceGroupTests {
    /// A group needs a name to be worth showing in the menu or offering in the
    /// picker, so a blank one cannot be saved. The same rule `AgentDefinition` uses.
    @Test func aGroupWithANameIsValid() {
        #expect(WorkspaceGroup(name: "Work").isValid)
    }

    @Test func aGroupWithABlankNameIsInvalid() {
        #expect(!WorkspaceGroup(name: "   ").isValid)
        #expect(!WorkspaceGroup(name: "").isValid)
    }

    /// The name as the menu and the picker show it, trimmed the way the command in an
    /// agent is: it is typed into a text field.
    @Test func displayNameTrimsWhitespace() {
        #expect(WorkspaceGroup(name: "  Private  ").displayName == "Private")
    }

    /// Identity is the id, not the name, so renaming a group keeps every workspace
    /// assigned to it. Two groups sharing a name are still two groups.
    @Test func twoGroupsWithTheSameNameAreNotEqual() {
        #expect(WorkspaceGroup(name: "Work") != WorkspaceGroup(name: "Work"))
    }

    @Test func aGroupEqualsItself() {
        let group = WorkspaceGroup(name: "Work")
        #expect(group == group)
    }
}
