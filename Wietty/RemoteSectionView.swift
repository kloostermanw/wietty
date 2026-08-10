import SwiftUI
import ItermplexShared

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
    @Binding var collapsedCards: Set<UUID>

    private var key: String { "remote-\(store.connection.id.uuidString)" }

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
            collapsed: collapsedCards.contains(project.id),
            gitInfo: decoded.gitInfo[project.id],
            runState: { decoded.runStates[$0.id] ?? .exited },
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

    private func toggleCollapsed(_ id: UUID) {
        if collapsedCards.contains(id) {
            collapsedCards.remove(id)
        } else {
            collapsedCards.insert(id)
        }
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
