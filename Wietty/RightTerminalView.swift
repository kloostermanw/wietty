import SwiftUI
import WiettyShared

/// The right half of the main window: whatever is selected, and nothing else.
///
/// Four things can be drawn here and they are not interchangeable. A local
/// terminal is a libghostty surface the app owns and keeps alive for the row's
/// whole life (`LocalTerminalView`). A remote one is a SwiftTerm view over a socket
/// to another Mac (`RemoteTerminalView`) that exists only while it is on screen. A
/// process log is text this app already holds (`ProcessLogView`). Settings is a
/// form (`SettingsView`), here rather than in a window of its own. This view is the
/// seam, and it holds nothing itself.
struct RightTerminalView: View {
    let store: ProjectStore
    let stack: GhosttyStack
    /// For resolving a selected remote session to the connection that serves it.
    /// Observed rather than read once: removing a connection has to take its
    /// terminal off the screen.
    @ObservedObject var remoteConnections: RemoteConnectionsStore
    /// Only for `SettingsView`, which edits the connection list and has to make the
    /// controller resync when it does.
    @ObservedObject var remoteWorkspaces: RemoteWorkspacesController
    let selection: PaneSelection

    var body: some View {
        // One branch for local and nothing selected, deliberately. They are the same
        // view with a different argument, and splitting them would give SwiftUI two
        // identities: selecting the first terminal after a launch would then dismantle
        // the placeholder's container and re-parent a live surface into a fresh one
        // for no reason.
        switch selection {
        case let .remote(session):
            remote(session)
        case let .processLog(log):
            ProcessLogView(store: store, log: log)
        case .settings:
            // The same floor the other branches carry. The window's minimum size is
            // built from it, so a panel that asked for its own size would change how
            // small the window can get depending on what is on screen.
            SettingsView(store: store, remoteConnections: remoteConnections,
                         remoteWorkspaces: remoteWorkspaces)
                .frame(minWidth: SidebarWidth.paneMinimum,
                       minHeight: SidebarWidth.paneMinimumHeight,
                       maxHeight: .infinity)
        case .local, .none:
            LocalTerminalView(stack: stack, session: selection.localSession)
        }
    }

    @ViewBuilder private func remote(_ session: RemoteSessionRef) -> some View {
        if let connection = remoteConnections.connections
            .first(where: { $0.id == session.connectionId }) {
            RemoteTerminalView(remoteConnection: connection, sessionId: session.sessionId)
                // Load bearing. `RemoteTerminalView` opens its connection in
                // `makeNSView` and its `updateNSView` does nothing on purpose,
                // because the tab bar keyed every tab's view by tab id and a changed
                // session always meant a new view. One pane position does not get
                // that for free: without an id of its own, switching from one remote
                // session to another would reuse this view and keep the first
                // session's connection while claiming to show the second. The id is
                // also what detaches, since discarding the view runs
                // `dismantleNSView`, which stops the connection.
                .id(session)
                .frame(minWidth: SidebarWidth.paneMinimum,
                       minHeight: SidebarWidth.paneMinimumHeight,
                       maxHeight: .infinity)
        } else {
            // The connection was removed while its terminal was on screen. Same
            // wording the tabbed window uses, because it is the same situation.
            ContentUnavailableView("Connection removed", systemImage: "bolt.slash")
                .frame(minWidth: SidebarWidth.paneMinimum,
                       minHeight: SidebarWidth.paneMinimumHeight,
                       maxHeight: .infinity)
        }
    }
}
