import Foundation

/// One entry in the app menu's Group submenu: "All", then one per group. Values
/// rather than closures, so the menu's shape can be asserted without opening it.
/// `WiettyApp`'s Group command maps each onto the selection it stands for.
struct WorkspaceGroupMenuItem: Identifiable, Equatable {
    /// The group this entry selects, or nil for "All".
    let id: UUID?
    let title: String
    /// Whether this is the group the sidebar is currently filtered to, drawn with a
    /// checkmark.
    let isSelected: Bool
}

/// The Group submenu's contents and the sidebar filter that the active group drives.
enum WorkspaceGroupMenu {
    /// What the "show everything" entry is called.
    static let allTitle = "All"

    /// "All" first, then the groups in list order. Exactly one entry is selected: a
    /// group when its id is active, "All" when nothing is.
    static func items(groups: [WorkspaceGroup], selected: UUID?) -> [WorkspaceGroupMenuItem] {
        var items = [WorkspaceGroupMenuItem(id: nil, title: allTitle, isSelected: selected == nil)]
        for group in groups {
            items.append(WorkspaceGroupMenuItem(
                id: group.id, title: group.displayName, isSelected: selected == group.id))
        }
        return items
    }

    /// The workspaces a given selection shows: every one under "All" (nil), otherwise
    /// only the ones filed under that group. An unassigned workspace matches no group,
    /// so it appears only under "All".
    static func visible(_ projects: [Project], selected: UUID?) -> [Project] {
        guard let selected else { return projects }
        return projects.filter { $0.groupId == selected }
    }
}
