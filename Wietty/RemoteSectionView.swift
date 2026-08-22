import SwiftUI
import WiettyShared

/// One remote connection's sidebar section: a header, a status line while the connection
/// is not up, and otherwise the same `WorkspaceCardView` the local section uses.
///
/// This is a separate view for a reason that is easy to miss: `RemoteWorkspaceStore` is an
/// `ObservableObject` held inside `RemoteWorkspacesController`, and a nested observable's
/// changes do not redraw a view that only observes the controller. Observing the store
/// here is what makes pushed snapshots appear.
struct RemoteSectionView: View {
    @ObservedObject var store: RemoteWorkspaceStore
    let sections: SectionCollapseState
    let onRemoveConnection: () -> Void
    let onAttach: (TerminalRef) -> Void
    /// Whether a row is the terminal the main window's pane is showing. Answered by
    /// `ContentView`, which is where the pane's selection lives.
    let isSelected: (TerminalRef) -> Bool

    private var key: String { "remote-\(store.connection.id.uuidString)" }

    /// Where one workspace card's collapse is stored.
    ///
    /// Both ids, because a workspace id is only unique on the Mac that owns it: two
    /// connections can serve a workspace carrying the same id (the same folder cloned
    /// onto a second Mac, or a restored backup), and collapsing one card must not
    /// collapse the other's.
    ///
    /// The string itself is a `UserDefaults` compatibility surface, and
    /// `RemoteCardCollapseTests.keyHasTheStoredShape` pins it for that reason:
    /// changing the prefix, the separator or the order of the two ids forgets every
    /// card anyone has expanded, on the next launch, with nothing in the app to
    /// notice. Static so a test can ask for a key without building the view.
    static func cardKey(connectionId: UUID, workspaceId: UUID) -> String {
        "remote-card-\(connectionId.uuidString)-\(workspaceId.uuidString)"
    }

    var body: some View {
        SidebarSectionHeaderView(
            title: store.connection.name,
            collapsed: sections.isCollapsed(key),
            onToggle: { sections.setCollapsed(key, !sections.isCollapsed(key)) },
            buttons: [
                .init(system: "arrow.clockwise", help: "Reconnect",
                      action: { store.stop(); store.start() }),
                .init(system: "minus.circle", help: "Remove connection", action: onRemoveConnection)
            ]
        )
        if !sections.isCollapsed(key) {
            if store.state == .connected {
                let decoded = RemoteProjectAdapter.decoded(store.workspaces)
                ForEach(decoded.projects) { project in
                    card(project, decoded: decoded)
                    if project.id != decoded.projects.last?.id {
                        Divider()
                    }
                }
            } else {
                Text(Self.stateText(store.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            if let error = store.lastActionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Only the actions with a server side endpoint do anything. The rest render but are
    /// wired to no-ops, because there is no remote equivalent to rename, remove, config
    /// sync, or process control.
    private func card(_ project: Project, decoded: DecodedRemoteWorkspaces) -> some View {
        WorkspaceCardView(
            project: project,
            collapsed: isCardCollapsed(project.id),
            gitInfo: decoded.gitInfo[project.id],
            runState: { decoded.runStates[$0.id] ?? .exited },
            // The served side reports each session's run state authoritatively, so
            // a green glyph follows it directly rather than the optimistic local rule.
            isRunning: { decoded.runStates[$0.id] == .running },
            needsAttention: { decoded.attention.contains($0.id) },
            syncEnabled: true,
            configChanged: false,
            isLocalOnly: { _ in false },
            isSelected: isSelected,
            onActivate: { onAttach($0) },
            onRestartTerminal: { store.restart(sessionId: $0.sessionId) },
            onRenameTerminal: { _ in },
            onRemoveTerminal: { _ in },
            onCloseTerminal: { store.close(sessionId: $0.sessionId) },
            onOpenTerminal: { store.openTerminal(workspaceId: project.id) },
            onOpenClaude: { store.openClaude(workspaceId: project.id) },
            onRemoveProject: {},
            onToggleCollapsed: { toggleCollapsed(project.id) },
            onEnableSync: {},
            onApplyConfig: {},
            processes: [],
            onProcessStart: { _ in },
            onProcessStop: { _ in },
            onProcessRestart: { _ in },
            onProcessKill: { _ in },
            onOpenProcessLog: { _ in },
            tests: [],
            onTestRun: { _ in },
            onTestRunAll: {},
            onOpenTestLog: { _ in }
        )
    }

    /// A card nobody has toggled starts collapsed, unlike a section header and
    /// unlike a local card: a connection can serve a dozen workspaces, and drawing
    /// them all open pushes the Local section off the top of the sidebar.
    private func isCardCollapsed(_ workspaceId: UUID) -> Bool {
        sections.isCollapsed(Self.cardKey(connectionId: store.connection.id,
                                          workspaceId: workspaceId),
                             default: true)
    }

    /// The collapse is a preference of the Mac doing the viewing, stored here and
    /// never sent upstream: the serving Mac has its own idea of which of its cards
    /// are open, and one viewer must not rearrange another's sidebar.
    private func toggleCollapsed(_ id: UUID) {
        sections.setCollapsed(Self.cardKey(connectionId: store.connection.id, workspaceId: id),
                              !isCardCollapsed(id))
    }

    static func stateText(_ state: RemoteConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unauthorized: return "Unauthorized: check the connection's token."
        case .unreachable: return "Unreachable. Retrying…"
        }
    }
}
