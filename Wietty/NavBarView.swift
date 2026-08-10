import SwiftUI
import ItermplexShared

/// The bar across the top of the window's right half, above the pane.
///
/// It shows one thing for now, the workspace whatever is in the pane belongs to,
/// and it is its own view rather than a `Text` inside `ContentView` because more
/// is going into it.
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

    /// The bar's own height, so an empty bar takes the same room as a full one.
    static let height: CGFloat = 28

    private var title: String? {
        NavBarTitle.text(for: NavBarTitle.origin(for: selection,
                                                 projects: store.projects,
                                                 remote: remoteOrigin))
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
