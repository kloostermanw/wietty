import SwiftUI
import AppKit
import WiettyShared

struct ContentView: View {
    let store: ProjectStore
    let terminals: TerminalStack
    @ObservedObject var remoteConnections: RemoteConnectionsStore
    @ObservedObject var remoteWorkspaces: RemoteWorkspacesController
    let bells: BellNotifier
    /// What is covering the local terminal in the pane, and the rules that uncover
    /// it. See `PaneRouter`, which is where both live and why it is the app that owns
    /// them.
    let router: PaneRouter
    @Environment(\.openWindow) private var openWindow
    @State private var mcpHost: MCPServerHost?
    @State private var remoteServer: RemoteServer?
    @State private var isBusy = false
    @State private var renameTarget: (project: Project, ref: TerminalRef)?
    @State private var renameText = ""
    /// The workspace being renamed, and the name typed for it. Held here rather
    /// than on the card because the alert is the window's, not the row's.
    @State private var workspaceRenameTarget: Project?
    @State private var workspaceRenameText = ""
    /// The workspace and agent "Add Agent with args" was chosen for, and the
    /// arguments typed for it. Held here for the same reason the renames are: the
    /// dialog is the window's, not the card's.
    @State private var agentArgumentsTarget: (project: Project, agent: AgentDefinition)?
    @State private var agentArgumentsText = ""
    @State private var sections = SectionCollapseState()
    /// The local terminal the pane shows, mirrored from `GhosttyService` so a
    /// selection it makes redraws the pane. Nil on the other two substrates, where
    /// nothing reads it.
    @State private var selectedTerminal: String?
    /// The sidebar's live width while the divider is being dragged, and nil until
    /// one has been.
    ///
    /// Separate from `store.sidebarWidth`, which is the persisted value: a drag
    /// moves this on every frame and writes the store once, on release, so one drag
    /// is one `UserDefaults` write rather than hundreds. Nil rather than seeded,
    /// because a `@State` initial value cannot read `store` and seeding it from
    /// `.task` would lay the first frame out at the wrong width, before the hook
    /// runs. Falling back to the store on read has neither problem.
    @State private var sidebarWidth: Double?
    /// The width the current drag started from, so the gesture offsets a fixed
    /// origin instead of accumulating rounding on every frame.
    @State private var dragStartWidth: Double?
    /// Watches connected Macs for bells. Held here so its Combine subscriptions live
    /// as long as the window, and built once in `task`.
    @State private var remoteBells: RemoteBellObserver?

    var body: some View {
        // Not `HSplitView`. It handed the surplus to the sidebar as the window
        // grew, so widening the window widened the workspace list and left the
        // terminal pinned at its minimum, and it exposes neither a binding nor an
        // autosave name for the divider. An explicit sidebar width fixes both: the
        // sidebar is rigid, so the pane is the only flexible half and absorbs every
        // resize, and the number is ours to persist.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: SidebarWidth.clamped(desired: liveSidebarWidth.wrappedValue,
                                                       totalWidth: geometry.size.width))
                SidebarDivider(width: liveSidebarWidth,
                               dragStart: $dragStartWidth,
                               totalWidth: geometry.size.width,
                               onCommit: { store.sidebarWidth = $0 })
                // The bar belongs to the right column, not to the window: only the
                // divider is to its left, so the sidebar keeps the full height.
                VStack(spacing: 0) {
                    NavBarView(store: store, remoteWorkspaces: remoteWorkspaces,
                               selection: paneSelection,
                               onOpenSettings: { router.toggleSettings() })
                    Divider()
                    RightTerminalView(store: store, stack: terminals.ghostty,
                                      remoteConnections: remoteConnections,
                                      remoteWorkspaces: remoteWorkspaces,
                                      bells: bells,
                                      desktopNotifications: terminals.desktopNotifications,
                                      ghosttyColors: terminals.ghosttyColors,
                                      selection: paneSelection)
                }
                .frame(maxWidth: .infinity)
            }
        }
        // `GeometryReader` answers with whatever size it is offered and never
        // reports what its content needs, so the two halves' minimums would not
        // reach the window on their own: measured `contentMin=0.0x32.0`, and at 500
        // points the terminal ran 226 points off the right edge while the sidebar's
        // own content was squeezed under its 240. Restated here, which is the one
        // place that can still tell the window.
        .frame(minWidth: SidebarWidth.windowMinimumWidth,
               minHeight: SidebarWidth.windowMinimumHeight)
        .navigationTitle("")
        .task {
            store.startPeriodicRefresh()
            // libghostty or the bundled helper failing to start is reported the same
            // way a failed terminal action is, so the message is visible on launch
            // rather than only after the first click that fails. There is nothing to
            // fall back to, so this message is all the user gets.
            if let setupError = terminals.setupError { store.lastError = setupError }
            // PTYs die with the app, so every stored
            // session id is dead. Cleared before the monitor starts, so no event
            // can arrive for an id that is about to be wiped.
            store.clearDeadSessions()
            // The pane reads SwiftUI state, and the selection lives in
            // `GhosttyService`, which is where every path that changes it already
            // is: opening a terminal, focusing a row, closing one. Mirrored rather
            // than reached into, so a selection made from the MCP server or a
            // remote client redraws the pane the same way a click does.
            if let service = terminals.ghostty.ghosttyService {
                selectedTerminal = service.selected
                service.onSelectionChanged = { session in
                    selectedTerminal = session
                    // A local terminal coming into view takes the pane back from
                    // whatever was covering it, which is what makes opening or
                    // focusing one show it even while a remote session, a log or
                    // settings is on screen. Closing one local terminal while another
                    // remains also takes the pane, because the service selects that
                    // other one and this cannot tell it apart from a click.
                    //
                    // This is not the whole of it: `select` returns early when the
                    // session is already selected, so re-activating the terminal the
                    // pane was already showing arrives nowhere. `activate` clears the
                    // override itself for that reason.
                    router.localSelectionChanged(to: session)
                }
            }
            startBellNotifications()
            terminals.monitor.start { event in store.handle(event) }
            if mcpHost == nil {
                let host = MCPServerHost(router: MCPToolRouter(store: store), port: store.mcpPort,
                                         onStartupError: { message in store.mcpStartupError = message })
                mcpHost = host
                await host.start()
            }
            await syncRemoteServer()
            remoteWorkspaces.sync()
        }
        // A connection removed while its terminal is on screen takes the terminal
        // with it and puts the local one back. Without this the pane would sit on
        // `RightTerminalView`'s "Connection removed" placeholder with nothing in the
        // sidebar left to click out of it, since the rows went with the connection.
        // Keyed on the ids rather than the connections, so an edited name or token
        // does not count as a removal. The placeholder still earns its place: it
        // covers the frame between the store changing and this firing.
        .onChange(of: remoteConnections.connections.map(\.id)) { _, ids in
            router.connectionsChanged(to: ids)
        }
        // The same for a workspace removed while its own page is on screen: the card
        // went with it, so the page would be left with nothing in the sidebar to
        // click out of it. Keyed on the ids, so a rename is not a removal.
        .onChange(of: store.projects.map(\.id)) { _, ids in
            router.workspacesChanged(to: ids)
        }
        .onChange(of: store.remoteEnabled) { Task { await syncRemoteServer() } }
        .onChange(of: store.remotePort) { Task { await syncRemoteServer(forceRestart: true) } }
        .onChange(of: store.mcpPort) { Task { await restartMCPHost() } }
        .alert("Rename terminal", isPresented: renameIsPresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        store.rename(target.ref, in: target.project, to: trimmed)
                    }
                }
                renameTarget = nil
            }
        }
        .alert("Rename workspace", isPresented: workspaceRenameIsPresented) {
            TextField("Name", text: $workspaceRenameText)
            Button("Cancel", role: .cancel) { workspaceRenameTarget = nil }
            Button("Rename") {
                if let target = workspaceRenameTarget {
                    store.renameWorkspace(target, to: workspaceRenameText)
                }
                workspaceRenameTarget = nil
            }
        } message: {
            Text("The folder on disk keeps its own name. Clear the field to go back "
                 + "to that name, or to the one in this workspace's wietty.json.")
        }
        .alert("Arguments for \(agentArgumentsTarget?.agent.displayName ?? "")",
               isPresented: agentArgumentsIsPresented) {
            TextField("Arguments", text: $agentArgumentsText)
            Button("Cancel", role: .cancel) { agentArgumentsTarget = nil }
            Button("Add") {
                if let target = agentArgumentsTarget {
                    openAgent(target.agent, arguments: agentArgumentsText, in: target.project)
                }
                agentArgumentsTarget = nil
            }
        } message: {
            Text("Typed after the agent's command. Clear the field to run it with no "
                 + "arguments at all.")
        }
        .alert(
            store.lastError ?? "",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { presented in if !presented { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.lastError = nil }
        }
        // A sheet rather than an alert: the commands are the whole question, an alert
        // gives a list of shell lines no room, and this is the one prompt where
        // reading before pressing is the point.
        .sheet(item: Binding(
            get: { store.pendingConfigApproval },
            set: { if $0 == nil { store.declinePendingConfig() } }
        )) { request in
            ConfigApprovalView(
                request: request,
                onRun: { store.approvePendingConfig() },
                onCancel: { store.declinePendingConfig() }
            )
        }
    }

    /// What the pane shows and which row is marked, from the two pieces of state that
    /// live apart: the local selection in `GhosttyService`, and whatever covers it in
    /// `PaneRouter`.
    private var paneSelection: PaneSelection {
        .resolve(local: selectedTerminal, override: router.override)
    }

    /// The width to lay out and to drag: whatever this window's drag left, or the
    /// persisted one until a drag replaces it. Reading the store here is what makes
    /// the first frame after a launch the right width.
    private var liveSidebarWidth: Binding<Double> {
        Binding(
            get: { sidebarWidth ?? store.sidebarWidth },
            set: { sidebarWidth = $0 }
        )
    }

    private var workspaceRenameIsPresented: Binding<Bool> {
        Binding(
            get: { workspaceRenameTarget != nil },
            set: { presented in if !presented { workspaceRenameTarget = nil } }
        )
    }

    /// Opens the rename dialog pre-filled with the name the workspace shows now, so
    /// the user edits rather than retypes, and so clearing the field is visibly the
    /// way to undo a rename.
    private func startWorkspaceRename(for project: Project) {
        workspaceRenameText = project.name
        workspaceRenameTarget = project
    }

    private var agentArgumentsIsPresented: Binding<Bool> {
        Binding(
            get: { agentArgumentsTarget != nil },
            set: { presented in if !presented { agentArgumentsTarget = nil } }
        )
    }

    private var renameIsPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { presented in if !presented { renameTarget = nil } }
        )
    }

    /// The workspace list: the left half of the window, beside the terminal pane.
    private var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                localSection
                ForEach(remoteConnections.connections) { connection in
                    if let remoteStore = remoteWorkspaces.stores[connection.id] {
                        RemoteSectionView(
                            store: remoteStore,
                            sections: sections,
                            onRemoveConnection: {
                                remoteConnections.remove(id: connection.id)
                                remoteWorkspaces.sync()
                            },
                            onAttach: { openRemoteTerminal(remoteStore, $0) },
                            isSelected: {
                                paneSelection.selects(remoteSession: $0.sessionId,
                                                      on: connection.id)
                            }
                        )
                    }
                }
            }
        }
        .frame(minWidth: 240)
        // The user's own sidebar colours, set once here and read by every card and
        // row under it (`EnvironmentValues.sidebarColors`). The background fills the
        // sidebar when a colour is set and is `Color.clear` otherwise, so an untouched
        // install keeps the system material.
        .foregroundStyle(store.sidebarColors.foreground ?? Color.primary)
        .background(store.sidebarColors.background ?? Color.clear)
        .environment(\.sidebarColors, store.sidebarColors)
        .disabled(isBusy)
        .overlay {
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var localSectionButtons: [SidebarSectionHeaderView.ButtonSpec] {
        Self.localSectionButtons(
            refresh: { Task { await store.refreshAllGitInfo() } },
            add: addProject)
    }

    /// The Local header's trailing buttons.
    ///
    /// A static function taking its actions rather than a computed property, so
    /// which buttons the header shows is asserted in CI rather than only checkable
    /// by looking at the window.
    static func localSectionButtons(refresh: @escaping () -> Void,
                                    add: @escaping () -> Void)
        -> [SidebarSectionHeaderView.ButtonSpec] {
        [.init(system: "arrow.clockwise", help: "Refresh git status", action: refresh),
         .init(system: "plus", help: "Add project folder", action: add)]
    }

    /// The Local header, and whether the section under it is collapsed. Titled only
    /// while there is a remote section to tell it apart from; see `LocalSectionHeader`.
    private var localHeader: LocalSectionHeader {
        .resolve(hasRemoteConnections: !remoteConnections.connections.isEmpty,
                 storedCollapsed: sections.isCollapsed("local"))
    }

    /// The workspaces the sidebar shows: every one when no group is active, otherwise
    /// only those filed under the selected group (unassigned workspaces show only under
    /// "All"). Computed once so the last-card divider below tests against what is
    /// actually drawn. Filtering hides rows without removing anything, so a hidden
    /// workspace's terminal keeps running and the pane is left undisturbed.
    private var visibleProjects: [Project] {
        WorkspaceGroupMenu.visible(store.projects, selected: store.selectedGroupId)
    }

    @ViewBuilder
    private var localSection: some View {
        let header = localHeader
        let visible = visibleProjects
        SidebarSectionHeaderView(
            title: header.title,
            collapsed: header.collapsed,
            onToggle: { sections.setCollapsed("local", !sections.isCollapsed("local")) },
            buttons: localSectionButtons
        )
        if !header.collapsed {
            ForEach(visible) { project in
                WorkspaceCardView(
                    project: project,
                    collapsed: project.collapsed,
                    gitInfo: store.gitInfo[project.id],
                    runState: { store.runState(for: $0) },
                    needsAttention: { store.attention.contains($0.id) },
                    syncEnabled: store.isSyncEnabled(project),
                    configChanged: store.configChangedOnDisk.contains(project.id),
                    isLocalOnly: { store.localOnlyTerminals.contains($0.id) },
                    // The same selection the pane is drawn from, so the highlighted
                    // row and the terminal on screen cannot disagree.
                    isSelected: { paneSelection.selects(localSession: $0.sessionId) },
                    // A process row is marked while its log is in the pane, the same
                    // way a terminal row is marked while its terminal is. Only the
                    // local card: a remote card's processes are not shown here.
                    isProcessSelected: {
                        paneSelection.selects(processLog: ProcessLogRef(projectId: project.id,
                                                                        name: $0))
                    },
                    agents: store.agents,
                    onActivate: { activate($0, in: project) },
                    onRestartTerminal: { restartTerminal($0, in: project) },
                    onRenameTerminal: { startRename($0, in: project) },
                    onRemoveTerminal: { store.removeTerminal($0, in: project) },
                    onCloseTerminal: { closeTerminal($0, in: project) },
                    onOpenTerminal: { openTerminal(for: project) },
                    onOpenClaude: { openClaude(for: project) },
                    onAddAgent: { openAgent($0, in: project) },
                    onAddAgentWithArgs: { startAgentArguments($0, in: project) },
                    onAddWorkspace: addProject,
                    onRemoveProject: { store.remove(project) },
                    onEditWorkspace: { router.show(.workspaceSettings(project.id)) },
                    onRenameWorkspace: { startWorkspaceRename(for: project) },
                    onToggleCollapsed: { store.toggleCollapsed(project) },
                    onEnableSync: { store.enableConfigSync(for: project) },
                    onApplyConfig: { store.applyConfigChanges(for: project) },
                    processes: store.processes.processes(for: project.id),
                    onProcessStart: { $0.start() },
                    onProcessStop: { $0.stop() },
                    onProcessRestart: { $0.restart() },
                    onProcessKill: { $0.kill() },
                    onOpenProcessLog: { openProcessLog($0, in: project) },
                    tests: store.testSupervisor.tests(for: project.id),
                    onTestRun: { store.testSupervisor.run(projectId: project.id, name: $0.name) },
                    onTestRunAll: { store.testSupervisor.runAll(projectId: project.id) },
                    onOpenTestLog: { openTestLog($0, in: project) }
                )
                .draggable(project.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
                    store.move(id: dragged, before: project.id)
                    return true
                }
                if project.id != visible.last?.id {
                    Divider()
                }
            }
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
                    store.moveToEnd(id: dragged)
                    return true
                }
        }
    }

    /// Starts or stops `RemoteServer` to match `store.remoteEnabled`. When the
    /// port changes, `forceRestart` tears down the running server first so it
    /// rebinds on the new port.
    private func syncRemoteServer(forceRestart: Bool = false) async {
        if store.remoteEnabled {
            if forceRestart, remoteServer != nil {
                remoteServer?.stop()
                remoteServer = nil
            }
            if remoteServer == nil {
                store.remoteStartupError = nil
                let server = RemoteServer(store: store, streamer: terminals.streamer,
                                          token: store.remoteToken, port: store.remotePort,
                                          onStartupError: { message in store.remoteStartupError = message })
                remoteServer = server
                await server.start()
            }
        } else {
            remoteServer?.stop()
            remoteServer = nil
            // The hub is deliberately left running. It is shared with the pane's
            // own viewer and its `stop()` cancels the flush timer for good, so
            // stopping it here would leave every later local viewer silent.
            // Tearing the server down closes its sockets anyway, and each socket
            // detaches its own viewer on the way out.
            store.remoteStartupError = nil
        }
    }

    /// Recreates the MCP host on the currently configured port.
    private func restartMCPHost() async {
        mcpHost?.stop()
        store.mcpStartupError = nil
        let host = MCPServerHost(router: MCPToolRouter(store: store), port: store.mcpPort,
                                 onStartupError: { message in store.mcpStartupError = message })
        mcpHost = host
        await host.start()
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            store.addProject(url: url)
        }
    }

    private func openTerminal(for project: Project) {
        Task {
            isBusy = true
            await store.openTerminal(for: project)
            isBusy = false
        }
    }

    private func openClaude(for project: Project) {
        Task {
            isBusy = true
            await store.openClaude(for: project)
            isBusy = false
        }
    }

    /// Starts a row for one of the configured agents.
    ///
    /// - Parameter arguments: what the "with args" dialog collected, or nil for the
    ///   plain menu item, which uses the agent's defaults.
    private func openAgent(_ agent: AgentDefinition, arguments: String? = nil, in project: Project) {
        Task {
            isBusy = true
            await store.openAgent(agent, arguments: arguments, for: project)
            isBusy = false
        }
    }

    /// Opens the arguments dialog pre-filled with the agent's defaults, so a user
    /// edits them rather than retyping them, and so clearing the field is visibly the
    /// way to run the agent bare.
    private func startAgentArguments(_ agent: AgentDefinition, in project: Project) {
        agentArgumentsText = agent.defaultArguments
        agentArgumentsTarget = (project, agent)
    }

    /// Opens the row's terminal if it was gone, starts its agent if it had
    /// stopped, and shows it.
    ///
    /// Selecting a session is what puts its surface in the pane, and `store.activate`
    /// does that. The override is cleared here rather than left to the selection
    /// callback because `GhosttyService.select` returns early when the session is
    /// already the selected one, and that is precisely the row a user clicks to get
    /// out of whatever is covering it: the terminal the pane was showing a moment ago.
    /// Relying on the callback alone left the click dead and, with settings on screen,
    /// left the panel with no exit at all.
    ///
    /// Before the await, so the pane switches on the click rather than after a
    /// reopen that may take a moment.
    private func activate(_ ref: TerminalRef, in project: Project) {
        router.localTerminalActivated()
        Task {
            isBusy = true
            await store.activate(ref, in: project)
            isBusy = false
        }
    }

    private func closeTerminal(_ ref: TerminalRef, in project: Project) {
        Task {
            isBusy = true
            await store.closeTerminal(ref, in: project)
            isBusy = false
        }
    }

    private func restartTerminal(_ ref: TerminalRef, in project: Project) {
        Task {
            isBusy = true
            await store.restartTerminal(sessionId: ref.sessionId)
            isBusy = false
        }
    }

    private func startRename(_ ref: TerminalRef, in project: Project) {
        renameText = ref.label
        renameTarget = (project, ref)
    }

    /// Puts a process's log in the pane. Deliberately reached only from "Open log"
    /// and the context menu, never from a click on the row: a process row has no
    /// activate action, so clicking one still does nothing.
    private func openProcessLog(_ process: ManagedProcess, in project: Project) {
        router.show(.log(ProcessLogRef(projectId: project.id, name: process.name)))
    }

    private func openTestLog(_ test: ManagedProcess, in project: Project) {
        router.show(.log(ProcessLogRef(projectId: project.id, name: test.name, isTest: true)))
    }

    /// Clicking a remote row does what clicking a local one does: the serving Mac
    /// opens a session for the row when it has none, and only then does the pane
    /// attach to it.
    ///
    /// The session id comes from the reply rather than from `ref`, because a revived
    /// row gets a *new* one and `ref` still carries the dead id the last snapshot
    /// described. Attaching to that is what put `[session ended]` in the pane with no
    /// way back to a working terminal.
    ///
    /// Awaited before the pane switches, unlike the local path, which switches first.
    /// Not because a local revival cannot renumber a row, it can and does: the
    /// difference is that the local switch never names a session. It only clears the
    /// pane's override (`PaneRouter.localTerminalActivated`) and lets the pane follow
    /// whatever the service ends up selecting, so a new session id is already
    /// accounted for by the time it matters. This path has to hand `showRemote` an
    /// id, and the only id worth handing it is the one this call is about to answer
    /// with.
    private func openRemoteTerminal(_ remoteStore: RemoteWorkspaceStore, _ ref: TerminalRef) {
        Task {
            isBusy = true
            let sessionId = await remoteStore.activate(refId: ref.id)
            isBusy = false
            if let message = Self.remoteActivationFailureMessage(
                sessionId: sessionId, lastActionError: remoteStore.lastActionError) {
                store.lastError = message
            }
            // Nil means the activation failed, and it has been said somewhere by now:
            // `remoteStore.lastActionError` under the connection's section, or the
            // alert the line above raises when the reply left that empty. Nothing is
            // attached either way: a pane showing a session that was never opened is
            // the failure this exists to prevent.
            guard let sessionId else { return }
            showRemote(RemoteSessionRef(connectionId: remoteStore.connection.id,
                                        sessionId: sessionId))
        }
    }

    /// What to say about an activation that answered no session id, or nil when
    /// there is nothing to say: a reply that named a session, or a failure the
    /// connection's own red caption already carries.
    ///
    /// The case left over is why the reply is not simply a `guard let`.
    /// `RemoteWorkspaceStore.activate` clears `lastActionError` on any 2xx and then
    /// answers nil for a body it could not read or that named an empty session, so a
    /// serving instance that says 200 and names nothing would leave a click with no
    /// pane, no caption and nothing written anywhere. That is this route's own dead
    /// click, one layer further out, and the alert is the only channel a viewer
    /// cannot miss.
    ///
    /// A static function taking both halves rather than reading the store, so which
    /// replies are reported is asserted in CI rather than only reachable by pointing
    /// this Mac at a mismatched one.
    static func remoteActivationFailureMessage(sessionId: String?,
                                               lastActionError: String?) -> String? {
        guard sessionId == nil, lastActionError == nil else { return nil }
        return "The remote answered without naming a session to show. "
            + "It may be running an older version of Wietty."
    }

    /// Shows a remote session in the main window's pane, the same one the local
    /// terminals use, so it arrives beside the sidebar with no second window.
    private func showRemote(_ session: RemoteSessionRef) {
        router.show(.remote(session))
    }

    // MARK: - Bells

    /// Wires bells to Notification Center: local ones from the store, remote ones
    /// from every connection's snapshots, and a tap back to whatever shows a
    /// terminal.
    ///
    /// Called before `terminals.monitor.start`, so no bell can arrive before there is
    /// somewhere for it to go.
    private func startBellNotifications() {
        bells.onTap = { target in showBell(target) }
        store.onBell = { project, ref in
            guard BellAlert.shouldPost(
                appIsFrontmost: NSApp.isActive,
                terminalIsOnScreen: paneSelection.selects(localSession: ref.sessionId)) else { return }
            let notification = BellNotification.local(workspace: project.name,
                                                      label: ref.label, refId: ref.id,
                                                      sound: store.bellSound)
            Task { await bells.post(notification) }
        }
        // A notification the process asked for by name, with its own words. The same
        // on screen rule as a bell: a terminal the user is already looking at needs
        // no banner. The rule that differs is upstream, in the store, which reports
        // every one of these rather than only the first per flag.
        store.onNotification = { project, ref, title, body in
            guard BellAlert.shouldPost(
                appIsFrontmost: NSApp.isActive,
                terminalIsOnScreen: paneSelection.selects(localSession: ref.sessionId)) else { return }
            let notification = BellNotification.sent(workspace: project.name, label: ref.label,
                                                     refId: ref.id, title: title, body: body,
                                                     sound: store.bellSound)
            Task { await bells.post(notification) }
        }
        // Visiting a row takes its notification back, so Notification Center does not
        // keep bells that have already been dealt with.
        store.onAttentionCleared = { ids in
            bells.withdraw(ids.map { .local(refId: $0) })
        }
        guard remoteBells == nil else { return }
        let observer = RemoteBellObserver { connection, diff in
            handleRemoteBells(connection: connection, diff: diff)
        }
        remoteBells = observer
        observer.start(controller: remoteWorkspaces)
    }

    private func handleRemoteBells(connection: UUID, diff: RemoteBellDiff) {
        // The connection's own name, because a bell says nothing useful without which
        // Mac it came from. Falls back rather than dropping the notification: a
        // connection being renamed at that instant is not a reason to stay silent.
        let name = remoteConnections.connections.first { $0.id == connection }?.name ?? "Remote"
        for ringer in diff.ringing {
            let session = RemoteSessionRef(connectionId: connection, sessionId: ringer.sessionId)
            guard BellAlert.shouldPost(
                appIsFrontmost: NSApp.isActive,
                terminalIsOnScreen: paneSelection.selects(remoteSession: ringer.sessionId,
                                                         on: connection)) else { continue }
            let notification = BellNotification.remote(connection: name, workspace: ringer.workspace,
                                                       label: ringer.label, session: session,
                                                       sound: store.bellSound)
            Task { await bells.post(notification) }
        }
        bells.withdraw(diff.cleared.map {
            .remote(RemoteSessionRef(connectionId: connection, sessionId: $0))
        })
    }

    /// A tapped notification, which does exactly what clicking the row does, after
    /// bringing the window it lives in forward.
    ///
    /// `openWindow` rather than reaching into `NSApp.windows`, so this also works when
    /// the main window has been closed: for a `Window` scene it reopens a closed one
    /// and focuses an open one.
    private func showBell(_ target: BellTarget) {
        openWindow(id: WiettyApp.mainWindowID)
        NSApp.activate()
        switch target {
        case .local(let refId):
            // Gone in the meantime: a notification outlives the row it is about, and a
            // removed row has nothing to show.
            guard let found = store.session(withRefId: refId) else { return }
            activate(found.ref, in: found.project)
        case .remote(let session):
            // The same rule as the local case, on the connection rather than the row:
            // a notification outlives the connection it came from, and one that has
            // been removed has no session left to show.
            guard remoteWorkspaces.stores[session.connectionId] != nil else { return }
            showRemote(session)
        }
    }
}
