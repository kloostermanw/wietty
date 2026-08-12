import SwiftUI
import WiettyShared

/// The bar across the top of the window's right half, above the pane.
///
/// It says where what is in the pane comes from, and carries the buttons that act
/// on the pane rather than on a row: the gear, which is the only way into settings
/// that is visible in a window with no title bar.
///
/// Always present, including when nothing is selected. A bar that appeared and
/// disappeared would move the whole pane height with it, which is a jump for the
/// terminal underneath every time a selection is cleared.
struct NavBarView: View {
    let store: ProjectStore
    /// Observed, not read once: a remote workspace's name arrives in a snapshot and
    /// can change while its session is on screen.
    @ObservedObject var remoteWorkspaces: RemoteWorkspacesController
    let selection: PaneSelection
    let onOpenSettings: () -> Void

    /// The bar's own height, so an empty bar takes the same room as a full one.
    static let height: CGFloat = 28

    /// The bar's trailing buttons.
    ///
    /// A static function taking its actions rather than a computed property, for the
    /// same reason `ContentView.localSectionButtons` is one: which buttons the bar
    /// shows is then asserted in CI rather than only checkable by looking at the
    /// window.
    static func trailingButtons(openSettings: @escaping () -> Void)
        -> [SidebarSectionHeaderView.ButtonSpec] {
        [.init(system: "gearshape", help: "Settings", action: openSettings)]
    }

    private var title: String? {
        NavBarTitle.line(for: selection, projects: store.projects, remote: remoteOrigin)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let title {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            ForEach(Self.trailingButtons(openSettings: onOpenSettings)) { button in
                Button(action: button.action) {
                    Image(systemName: button.system)
                        // Marked while its panel is the thing in the pane, the same
                        // way the sidebar marks the row whose terminal is on screen.
                        .foregroundStyle(selection.showsSettings ? Color.accentColor
                                                                 : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(button.help)
                .accessibilityLabel(button.help)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }

    /// The connection's name and the workspace holding that session, from the live
    /// snapshot. Nil while a connection is still connecting, and for a session that
    /// has left the snapshot, which is what leaves the bar empty rather than stale.
    private func remoteOrigin(_ session: RemoteSessionRef) -> PaneOrigin? {
        guard let remoteStore = remoteWorkspaces.stores[session.connectionId] else { return nil }
        guard let workspace = remoteStore.workspaces.first(where: { workspace in
            workspace.sessions.contains { $0.sessionId == session.sessionId }
        }) else { return nil }
        return PaneOrigin(workspace: workspace.name, connection: remoteStore.connection.name)
    }
}
