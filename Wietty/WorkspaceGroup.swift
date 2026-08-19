import Foundation

/// One group a workspace can be filed under: "Work", "Private", whatever the user
/// typed. Picking a group in the app menu filters the sidebar to the workspaces
/// assigned to it; a workspace with no group shows only under "All".
///
/// A value type carrying the name and a stable id, like `AgentDefinition`. Identity
/// is the id rather than the name so a rename keeps every assignment: a workspace
/// remembers the group's id (`Project.groupId`), and the active-group selection
/// (`ProjectStore.selectedGroupId`) is that id too. Groups persist as
/// `group.<i>.*` lines in `~/.config/wietty/config`, a machine-local list the way
/// the agents are, and never travel into a workspace's `wietty.json`.
struct WorkspaceGroup: Identifiable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// A group with no name has nothing to label the menu item or the picker row, so
    /// it cannot be saved. The same gate `AgentDefinition.isValid` is.
    var isValid: Bool { !name.trimmed.isEmpty }

    /// The name as the menu and the picker show it, trimmed because it is typed into
    /// a text field.
    var displayName: String { name.trimmed }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
