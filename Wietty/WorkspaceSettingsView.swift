import SwiftUI

/// One workspace's own page, reached from "Edit workspace…" in its card's menu and
/// drawn in the pane beside the sidebar, the way the app's settings are.
///
/// Empty on purpose. The workspace things worth a page (the rows, the name, the
/// `wietty.json` the card already syncs) are each reachable from the card itself
/// today, so this exists ahead of the settings that will move here rather than
/// alongside a half of them. The wording says so, because a page that drew nothing
/// would read as a page that failed to load.
///
/// The strings are statics rather than literals in the body for the same reason
/// `SettingsTab` is a pure type: what a screen says is a fact about the app, and a
/// fact about the app belongs in CI.
struct WorkspaceSettingsView: View {
    static let title = "No workspace settings yet"
    static let message = "Settings for this workspace will appear here. Its terminals, "
        + "agents and processes are on the card in the sidebar."
    static let systemImage = "slider.horizontal.3"

    /// The workspace this page is about, or nil when it has been removed while the
    /// page was up. `PaneRouter.workspacesChanged` takes the page off the screen a
    /// moment later; this covers the frame in between, the way the pane's "Connection
    /// removed" placeholder does.
    let project: Project?

    var body: some View {
        if project == nil {
            ContentUnavailableView("Workspace removed", systemImage: "folder.badge.minus")
        } else {
            ContentUnavailableView(Self.title, systemImage: Self.systemImage,
                                   description: Text(Self.message))
        }
    }
}
