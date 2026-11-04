import SwiftUI
import WiettyShared

/// The bar across the top of the window's right half, above the pane.
///
/// It says where what is in the pane comes from, and carries the buttons that act on
/// the pane rather than on a row: the gear, which is the only way into settings that
/// is inside the window. The app menu's item and ⌘, are the other two.
///
/// It sits in the window's top row, beside the traffic lights: the window has no
/// title bar of its own and its content runs up under where one would be, so this
/// bar and `SidebarTopBar` are that row. See `TitleBarRow.swift`.
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
                    // Not a target, so a drag that starts on the title moves the
                    // window like one on the empty bar beside it.
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            ForEach(Self.trailingButtons(openSettings: onOpenSettings)) { button in
                // Tinted while its panel is the thing in the pane. The sidebar marks
                // the row whose terminal is on screen with a background fill instead
                // (`SidebarRowBackground`); what is marked is the same idea, how it is
                // drawn is not, because a 28 point bar has no room for a fill that
                // would not read as a second selection.
                TitleBarButton(spec: button, highlighted: selection.showsSettings)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
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
