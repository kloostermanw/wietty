import SwiftUI

struct WorkspaceCardView: View {
    let project: Project
    let collapsed: Bool
    let gitInfo: GitInfo?
    let runState: (TerminalRef) -> ClaudeRunState
    let needsAttention: (TerminalRef) -> Bool
    let syncEnabled: Bool
    let configChanged: Bool
    let isLocalOnly: (TerminalRef) -> Bool
    /// Whether a row is the terminal the pane is showing, so the sidebar says which
    /// one is on screen. Defaulted so a caller that never marks a row can leave it
    /// out.
    var isSelected: (TerminalRef) -> Bool = { _ in false }
    /// The same question for a process row, by name. Defaulted for the same reason:
    /// a remote card's processes are not this app's to show.
    var isProcessSelected: (String) -> Bool = { _ in false }
    /// The agents the two "Add Agent" submenus offer, in menu order. Empty on a
    /// remote card, which offers neither: those are this Mac's agents.
    var agents: [AgentDefinition] = []
    /// A tap on a row, which shows that terminal in the pane.
    let onActivate: (TerminalRef) -> Void
    let onRestartTerminal: (TerminalRef) -> Void
    let onRenameTerminal: (TerminalRef) -> Void
    let onRemoveTerminal: (TerminalRef) -> Void
    let onCloseTerminal: (TerminalRef) -> Void
    let onOpenTerminal: () -> Void
    let onOpenClaude: () -> Void
    /// Starts one of the agents above with its default arguments.
    var onAddAgent: (AgentDefinition) -> Void = { _ in }
    /// The same, after asking what to run it with.
    var onAddAgentWithArgs: (AgentDefinition) -> Void = { _ in }
    /// Adds another workspace, which is what the `+` in the Local header does. Here
    /// too because a right click on a card is where a user already is when they want
    /// one more.
    var onAddWorkspace: () -> Void = {}
    let onRemoveProject: () -> Void
    /// Opens this workspace's own page in the pane. Nil on a remote card, whose
    /// workspace is not this app's to edit, and the menu item is then absent.
    var onEditWorkspace: (() -> Void)?
    /// Renames the workspace. Nil on a remote card, whose name belongs to the Mac
    /// serving it, and the menu item is then absent.
    var onRenameWorkspace: (() -> Void)?
    let onToggleCollapsed: () -> Void
    let onEnableSync: () -> Void
    let onApplyConfig: () -> Void
    let processes: [ManagedProcess]
    let onProcessStart: (ManagedProcess) -> Void
    let onProcessStop: (ManagedProcess) -> Void
    let onProcessRestart: (ManagedProcess) -> Void
    let onProcessKill: (ManagedProcess) -> Void
    let onOpenProcessLog: (ManagedProcess) -> Void
    let tests: [ManagedProcess]
    let onTestRun: (ManagedProcess) -> Void
    let onTestRunAll: () -> Void
    let onOpenTestLog: (ManagedProcess) -> Void

    @Environment(\.sidebarColors) private var sidebarColors

    /// The card is active when it owns the terminal the pane is showing, which is what
    /// the active-workspace colours highlight. Derived from the same `isSelected` the
    /// rows use, so the card and its rows cannot disagree about which is on screen.
    private var isActive: Bool { project.terminals.contains(where: isSelected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !collapsed {
                if let gitInfo {
                    IssuePRLineView(
                        branch: gitInfo.branch,
                        issueNumber: gitInfo.issueNumber,
                        issueURL: gitInfo.issueURL,
                        prNumber: gitInfo.prNumber,
                        prURL: gitInfo.prURL
                    )
                    .padding(.leading, 24)
                }
                if let checks = gitInfo?.checks {
                    ChecksLineView(summary: checks)
                        .padding(.leading, 24)
                }
                if !tests.isEmpty {
                    TestProcessesLineView(
                        tests: tests,
                        onRun: onTestRun,
                        onRunAll: onTestRunAll,
                        onOpenLog: onOpenTestLog,
                        onCopyId: { copyManagedProcessId($0, isTest: true) }
                    )
                    .padding(.leading, 24)
                }
                children
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundStyle(activeForeground)
        .background(activeBackground)
        .contentShape(Rectangle())
        .animation(.default, value: collapsed)
    }

    /// The active-workspace background, drawn only when this card owns the selected
    /// terminal and the user set a colour. `Color.clear` otherwise, so an untouched
    /// install draws no card background and nothing changes.
    @ViewBuilder private var activeBackground: some View {
        if let fill = WorkspaceHighlight.resolve(isActive: isActive)
            .background(active: sidebarColors.activeWorkspaceBackground) {
            fill
        } else {
            Color.clear
        }
    }

    /// The active-workspace foreground, applied the same way. `primary` when it does
    /// not apply, which is the default a card's text already draws in.
    private var activeForeground: AnyShapeStyle {
        if isActive, let foreground = sidebarColors.activeWorkspaceForeground {
            return AnyShapeStyle(foreground)
        }
        return AnyShapeStyle(.primary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)
            Text(project.name)
                .font(.title3)
                .lineLimit(1)
                .truncationMode(.middle)
            if configChanged {
                Button(action: onApplyConfig) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.orange)
                        .help("wietty.json changed on disk. Click to apply.")
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            if !collapsed {
                VStack(alignment: .trailing, spacing: 2) {
                    if let gitInfo, gitInfo.hasBase {
                        AheadBehindView(
                            label: gitInfo.baseRef ?? "base",
                            behind: gitInfo.baseBehind,
                            ahead: gitInfo.baseAhead
                        )
                    }
                    if let gitInfo, gitInfo.hasUpstream {
                        AheadBehindView(
                            label: gitInfo.upstreamRef ?? "origin/\(gitInfo.branch)",
                            behind: gitInfo.behind,
                            ahead: gitInfo.ahead
                        )
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleCollapsed() }
        .contextMenu {
            // Built from `WorkspaceMenu` rather than written out here, so which
            // items a card offers is asserted in CI rather than only by right
            // clicking one. This view supplies the actions, which is the half that
            // needs a card.
            ForEach(WorkspaceMenu.items(isLocal: onEditWorkspace != nil,
                                        syncEnabled: syncEnabled)) { item in
                menuItem(item)
            }
        }
    }

    @ViewBuilder private func menuItem(_ item: WorkspaceMenuItem) -> some View {
        switch item {
        case .addTerminal:
            Button(item.title, action: onOpenTerminal)
        case .addAgent:
            agentSubmenu(item, action: onAddAgent)
        case .addAgentWithArgs:
            agentSubmenu(item, action: onAddAgentWithArgs)
        case .addClaude:
            Button(item.title, action: onOpenClaude)
        case .addWorkspace:
            Button(item.title, action: onAddWorkspace)
        case .separator:
            Divider()
        case .editWorkspace:
            // Present only when the action is, which is the same question
            // `WorkspaceMenu` was asked to build the list. The `if let` is for the
            // closure, not for the item.
            if let onEditWorkspace {
                Button(item.title, action: onEditWorkspace)
            }
        case .renameWorkspace:
            if let onRenameWorkspace {
                Button(item.title, action: onRenameWorkspace)
            }
        case .enableConfigSync:
            Button(item.title, action: onEnableSync)
        case .removeWorkspace:
            Button(item.title, action: onRemoveProject)
        }
    }

    /// One of the two agent submenus. Empty is a state worth drawing: a submenu with
    /// nothing in it reads as a menu that failed to build, so it says where agents
    /// come from instead.
    @ViewBuilder private func agentSubmenu(_ item: WorkspaceMenuItem,
                                           action: @escaping (AgentDefinition) -> Void)
        -> some View {
        Menu(item.title) {
            if agents.isEmpty {
                Button(WorkspaceMenu.noAgents) {}.disabled(true)
            } else {
                ForEach(agents) { agent in
                    Button(agent.displayName) { action(agent) }
                }
            }
        }
    }

    @ViewBuilder private func terminalRowMenuItem(_ item: TerminalRowMenuItem, ref: TerminalRef) -> some View {
        switch item {
        case .rename: Button(item.title) { onRenameTerminal(ref) }
        // Copies the row's `sessionId`, which is what the MCP tools resolve, so a
        // prompt can point another agent straight at this session.
        case .copyId: Button(item.title) { Clipboard.copy(ref.sessionId) }
        case .remove: Button(item.title) { onRemoveTerminal(ref) }
        case .close: Button(item.title) { onCloseTerminal(ref) }
        }
    }

    /// The pasteboard handle for a process or test row: its `ManagedProcessID`, which
    /// the MCP `get_managed_process_*` tools resolve. A process and a test may share a
    /// name, so the handle carries which one this is.
    private func copyManagedProcessId(_ process: ManagedProcess, isTest: Bool) {
        Clipboard.copy(ManagedProcessID.string(projectId: project.id, name: process.name, isTest: isTest))
    }

    private var children: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(.secondary.opacity(0.25))
                .frame(width: 1)
                .padding(.leading, 7)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                if !processes.isEmpty {
                    ForEach(processes) { process in
                        ProcessRowView(
                            process: process,
                            isSelected: isProcessSelected(process.name),
                            onStart: { onProcessStart(process) },
                            onStop: { onProcessStop(process) },
                            onRestart: { onProcessRestart(process) },
                            onKill: { onProcessKill(process) },
                            onOpenLog: { onOpenProcessLog(process) },
                            onCopyId: { copyManagedProcessId(process, isTest: false) }
                        )
                    }
                }
                ForEach(project.terminals) { ref in
                    TerminalRowView(
                        label: ref.label,
                        kind: ref.kind,
                        isExited: ref.kind == .claude && runState(ref) == .exited,
                        needsAttention: needsAttention(ref),
                        isLocalOnly: isLocalOnly(ref),
                        isSelected: isSelected(ref),
                        onPlay: { onActivate(ref) },
                        onStop: { onCloseTerminal(ref) },
                        onRestart: { onRestartTerminal(ref) }
                    )
                    .onTapGesture { onActivate(ref) }
                    .contextMenu {
                        // Built from `TerminalRowMenu` rather than written out here, so
                        // which items a row offers is asserted in CI (`TerminalRowMenuTests`)
                        // rather than only by right clicking one, the same as the header menu.
                        ForEach(TerminalRowMenu.items(kind: ref.kind)) { item in
                            terminalRowMenuItem(item, ref: ref)
                        }
                    }
                }
            }
        }
    }
}
