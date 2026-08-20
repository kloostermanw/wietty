import SwiftUI

/// One workspace's own page, reached from "Edit workspace…" in its card's menu and
/// drawn in the pane beside the sidebar, the way the app's settings are.
///
/// What it holds today is the workspace's group: pick one and the app menu's Group
/// submenu can filter the sidebar down to the workspaces filed under it. "None" leaves
/// the workspace out of every group, so it shows only under "All".
///
/// Which group a workspace is in is local to this machine, like its in-app name, so it
/// is set here and saved to `~/.config/wietty/config` rather than into the workspace's
/// `wietty.json`.
struct WorkspaceSettingsView: View {
    static let groupSectionTitle = "Group"
    /// Shown for "no group": the workspace is in none, and so appears only under "All".
    static let noGroupTitle = "None"
    static let systemImage = "slider.horizontal.3"

    /// The store the picker reads the group list from and writes the assignment back
    /// to. The page reflects a group added in Settings without being rebuilt.
    let store: ProjectStore

    /// The workspace this page is about, or nil when it has been removed while the
    /// page was up. `PaneRouter.workspacesChanged` takes the page off the screen a
    /// moment later; this covers the frame in between, the way the pane's "Connection
    /// removed" placeholder does.
    let project: Project?

    var body: some View {
        if let project {
            Form {
                Section(Self.groupSectionTitle) {
                    Picker(Self.groupSectionTitle, selection: groupBinding(for: project)) {
                        Text(Self.noGroupTitle).tag(UUID?.none)
                        ForEach(store.groups) { group in
                            Text(group.displayName).tag(UUID?.some(group.id))
                        }
                    }
                    .labelsHidden()
                    if store.groups.isEmpty {
                        Text("No groups yet. Add one in Settings › General, then it "
                             + "appears here to assign this workspace to.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Pick the group this workspace belongs to. Choose it in the "
                             + "app menu's Group submenu to show only its workspaces.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Workspace removed", systemImage: "folder.badge.minus")
        }
    }

    /// Reads the assignment from the live stored copy, not the passed-in `project`,
    /// which may predate an assignment made moments ago; writes it back through the
    /// store so it persists.
    private func groupBinding(for project: Project) -> Binding<UUID?> {
        Binding(
            get: { store.projects.first { $0.id == project.id }?.groupId },
            set: { store.assignGroup(project, to: $0) }
        )
    }
}
