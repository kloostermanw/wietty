import Foundation
import Observation
import os

/// Logging for the store.
///
/// `lastError` is how the store normally reports a failure, and it is the better
/// channel whenever there is still a row or a click for the message to belong to.
/// This is for the work that outlives what it belonged to, where an alert would
/// name something the user can no longer see.
enum StoreLog {
    static let store = Logger(subsystem: "eu.kloosterman.wietty", category: "store")
}

enum ClaudeRunState: Equatable {
    case running
    case exited
}

/// Errors surfaced by `ProjectStore`'s programmatic (MCP-facing) helpers.
enum StoreError: LocalizedError, Equatable {
    case unknownProject
    case unknownSession
    case terminal(String)

    var errorDescription: String? {
        switch self {
        case .unknownProject: return "No workspace has that id."
        case .unknownSession: return "No tracked terminal has that session id."
        case let .terminal(message): return message
        }
    }
}

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    var lastError: String?
    private(set) var gitInfo: [UUID: GitInfo] = [:]
    private(set) var attention: Set<UUID> = [] {
        didSet {
            // Every path that clears a flag, in one place. There are a dozen of them
            // (activating, closing, restarting, renaming, removing a row), and a hook
            // on each would be a hook forgotten on the next one.
            let cleared = oldValue.subtracting(attention)
            if !cleared.isEmpty { onAttentionCleared?(cleared) }
        }
    }
    /// Called when a bell arrives for a tracked row, and only when it turns the
    /// row's attention flag on rather than on every bell. A program ringing in a
    /// loop is then one event, and visiting the row re-arms it.
    var onBell: ((Project, TerminalRef) -> Void)?
    /// Called with the row ids whose attention flag has just been cleared, so a
    /// notification about a bell that has been dealt with can be taken back.
    var onAttentionCleared: ((Set<UUID>) -> Void)?
    private(set) var jobNames: [UUID: String] = [:]

    /// Subscribers to `workspaceChanges()`, keyed by subscription id.
    private var changeSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Whether `armChangeTracking()` currently has an active `withObservationTracking`
    /// registration pending; avoids re-arming redundantly.
    private var changeTrackingArmed = false

    /// Terminal ids that are tracked locally but absent from the on-disk config
    /// (kept alive after an external removal). Cleared when the config is written.
    private(set) var localOnlyTerminals: Set<UUID> = []

    /// The exact bytes last read from or written to each workspace's config file,
    /// used to ignore the app's own writes when the watcher fires.
    private var lastConfigData: [UUID: Data] = [:]

    /// Workspaces whose on-disk config differs from what the app last saw; drives
    /// the "config changed" affordance on the card.
    private(set) var configChangedOnDisk: Set<UUID> = []

    private var watchers: [UUID: ConfigWatcher] = [:]

    /// One `.git` watcher per workspace, giving snappy local git feedback
    /// alongside the poll. Started for every workspace; a no-op for non-repos.
    private var gitWatchers: [UUID: GitDirWatcher] = [:]

    /// Foreground job names that mean "no agent running, just a shell".
    /// Confirmed/extended by the design spike (Task 0).
    static let shellJobNames: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "-fish",
        "sh", "-sh", "tcsh", "-tcsh", "login", "dash", "-dash"
    ]

    func isShell(_ jobName: String) -> Bool {
        Self.shellJobNames.contains(jobName)
    }

    private let defaults: UserDefaults
    private let service: TerminalService
    private let gitProvider: GitInfoProviding
    let processes: ProcessSupervisor
    let testSupervisor: TestSupervisor
    private let storageKey = "wietty.projects.bookmarks"
    private let badgeKey = "wietty.showWorkspaceBadge"
    private let intervalsKey = "wietty.checkIntervals"
    private let remoteEnabledKey = "wietty.remote.enabled"
    private let mcpPortKey = "wietty.mcpPort"
    private let remotePortKey = "wietty.remotePort"
    private let sidebarWidthKey = "wietty.sidebarWidth"

    /// Guards `clearDeadSessions()` against running twice in one process.
    ///
    /// Not a `UserDefaults` flag: the wipe must run
    /// again on every real relaunch, since a fresh process again has no live
    /// PTYs for whatever the last run stored. What must not happen is a second
    /// run inside the same process. `store` is `@State` on `WiettyApp`, one
    /// level above the `Window` that hosts `ContentView`, so it outlives the
    /// window: closing and reopening "Wietty" recreates the view and re-fires
    /// its `.task` against the same store, while `GhosttyStack`'s surfaces (also
    /// `@State` at the app level) keep running underneath it. An unguarded
    /// second run would read those live rows' real session ids as stale
    /// leftovers and wipe them, orphaning their PTYs and making running
    /// terminals look closed. The other steps in that `.task` already survive
    /// re-entry on their own (`mcpHost == nil`, and the remote sync against what is
    /// already connected). This is that same protection for a step with no such
    /// check built in.
    private var deadSessionsClearedThisLaunch = false

    /// Where job names come from.
    ///
    /// Injected rather than reached for: the answer needs a live `GhosttyService`,
    /// and this store is built before one exists and is exercised in tests without
    /// one. libghostty pushes a terminal's title and its bell through the action
    /// callback but says nothing about its foreground command, so that has to be
    /// asked for. The poll is cheap: one `tcgetpgrp` on the master fd plus one name
    /// lookup per live terminal, with no fork.
    private let jobEvents: @MainActor () -> [MonitorEvent]

    /// Allowed range for the configurable server ports (unprivileged, valid TCP).
    static let portRange = 1024...65535
    private var refreshTask: Task<Void, Never>?
    private var schedule = CheckSchedule()

    /// Cached owner/repo per workspace, set by the gitSync check and read by the
    /// pullRequest/ciChecks checks (and the issue/PR URL composition) so those
    /// checks do not need to re-derive it themselves.
    private var ownerRepo: [UUID: (String?, String?)] = [:]

    /// When on, newly opened (or reopened) sessions are given the workspace name as
    /// a badge. Off by default, and inert today: libghostty exposes no way to set a
    /// surface's title. Persisted; changing it affects future sessions only.
    var showWorkspaceBadge: Bool {
        didSet {
            guard showWorkspaceBadge != oldValue else { return }
            defaults.set(showWorkspaceBadge, forKey: badgeKey)
        }
    }

    /// Tier durations (seconds) for periodic checks. Clamped to valid ranges and
    /// persisted. Changing it takes effect on the next scheduler tick.
    var checkIntervals: CheckIntervals {
        didSet {
            let clamped = checkIntervals.clamped()
            if clamped != checkIntervals { checkIntervals = clamped; return } // re-enter with clamped value
            guard checkIntervals != oldValue else { return }
            defaults.set([checkIntervals.fast, checkIntervals.normal, checkIntervals.slow], forKey: intervalsKey)
        }
    }

    /// Whether the opt-in LAN remote terminal server runs. Off by default and
    /// persisted. `ContentView` starts/stops `RemoteServer` in response.
    var remoteEnabled: Bool {
        didSet {
            guard remoteEnabled != oldValue else { return }
            defaults.set(remoteEnabled, forKey: remoteEnabledKey)
        }
    }

    /// Port for the loopback MCP server. Clamped to `portRange` and persisted.
    /// Changing it takes effect when the MCP host is next (re)started.
    var mcpPort: Int {
        didSet {
            let clamped = Self.clampPort(mcpPort)
            if clamped != mcpPort { mcpPort = clamped; return }
            guard mcpPort != oldValue else { return }
            defaults.set(mcpPort, forKey: mcpPortKey)
        }
    }

    /// Port for the LAN remote terminal server. Clamped to `portRange` and
    /// persisted. Changing it takes effect when the server is next (re)started.
    var remotePort: Int {
        didSet {
            let clamped = Self.clampPort(remotePort)
            if clamped != remotePort { remotePort = clamped; return }
            guard remotePort != oldValue else { return }
            defaults.set(remotePort, forKey: remotePortKey)
        }
    }

    /// How wide the sidebar is, on the substrate where the main window is a
    /// sidebar plus a terminal pane. Persisted, so the divider stays where the
    /// user put it across relaunches.
    ///
    /// Clamped to the sidebar's own floor on the way in and out, because nothing
    /// guarantees a stored value came from this build or from a window this size.
    /// The upper bound is not applied here: it depends on the window's current
    /// width, which the store has no business knowing, so `ContentView` applies
    /// `SidebarWidth.clamped(desired:totalWidth:)` at layout time.
    ///
    /// Written on drag end rather than during the drag. The live width lives in
    /// `ContentView`'s own state while the divider is moving, so one drag is one
    /// write here instead of one per frame.
    var sidebarWidth: Double {
        didSet {
            let floored = max(sidebarWidth, SidebarWidth.minimum)
            if floored != sidebarWidth { sidebarWidth = floored; return }
            guard sidebarWidth != oldValue else { return }
            defaults.set(sidebarWidth, forKey: sidebarWidthKey)
        }
    }

    /// The shared secret required on every remote request and socket.
    let remoteToken: RemoteAccessToken

    /// Last error from starting the remote server (e.g. the port is in use), or
    /// nil when it started cleanly. Shown in Settings; not persisted.
    var remoteStartupError: String?

    /// Last error from starting the MCP server (e.g. the port is in use), or nil
    /// when it started cleanly. Shown in Settings; not persisted.
    var mcpStartupError: String?

    private static func clampPort(_ port: Int) -> Int {
        min(max(port, portRange.lowerBound), portRange.upperBound)
    }

    private struct StoredProject: Codable {
        var id: UUID
        var bookmark: Data
        var terminals: [TerminalRef]
        var terminalSeq: Int
        var claudeSeq: Int
        var displayName: String?
        var windowId: String?
        var collapsed: Bool

        init(id: UUID, bookmark: Data, terminals: [TerminalRef], terminalSeq: Int, claudeSeq: Int,
             displayName: String?, windowId: String?, collapsed: Bool) {
            self.id = id
            self.bookmark = bookmark
            self.terminals = terminals
            self.terminalSeq = terminalSeq
            self.claudeSeq = claudeSeq
            self.displayName = displayName
            self.windowId = windowId
            self.collapsed = collapsed
        }

        private enum CodingKeys: String, CodingKey {
            case id, bookmark, terminals, terminalSeq, claudeSeq, displayName, windowId, collapsed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Legacy records predate persisted ids; mint one so workspace ids
            // are stable from this launch onward.
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            bookmark = try container.decode(Data.self, forKey: .bookmark)
            terminals = try container.decode([TerminalRef].self, forKey: .terminals)
            terminalSeq = try container.decode(Int.self, forKey: .terminalSeq)
            claudeSeq = try container.decodeIfPresent(Int.self, forKey: .claudeSeq) ?? 0
            // Absent in every record written before workspaces could be renamed,
            // which is why it decodes optionally rather than requiring a migration.
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            windowId = try container.decodeIfPresent(String.self, forKey: .windowId)
            collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        }
    }

    init(
        defaults: UserDefaults = .standard,
        service: TerminalService,
        jobEvents: @escaping @MainActor () -> [MonitorEvent] = { [] },
        gitProvider: GitInfoProviding = GitInfoService(),
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        testSupervisor: TestSupervisor = TestSupervisor()
    ) {
        self.defaults = defaults
        self.service = service
        self.jobEvents = jobEvents
        self.gitProvider = gitProvider
        self.processes = processSupervisor
        self.testSupervisor = testSupervisor
        self.showWorkspaceBadge = defaults.bool(forKey: badgeKey)
        if let arr = defaults.array(forKey: intervalsKey) as? [Int], arr.count == 3 {
            self.checkIntervals = CheckIntervals(fast: arr[0], normal: arr[1], slow: arr[2]).clamped()
        } else {
            self.checkIntervals = .default
        }
        self.remoteEnabled = defaults.bool(forKey: remoteEnabledKey)
        let storedMCPPort = defaults.integer(forKey: mcpPortKey)
        self.mcpPort = storedMCPPort == 0 ? MCPServerHost.defaultPort : Self.clampPort(storedMCPPort)
        let storedRemotePort = defaults.integer(forKey: remotePortKey)
        self.remotePort = storedRemotePort == 0 ? RemoteServer.defaultPort : Self.clampPort(storedRemotePort)
        // `double(forKey:)` answers 0 for an absent key, which is also an
        // impossible width, so the two cases collapse into the same fallback.
        let storedSidebarWidth = defaults.double(forKey: sidebarWidthKey)
        self.sidebarWidth = storedSidebarWidth == 0
            ? SidebarWidth.default
            : max(storedSidebarWidth, SidebarWidth.minimum)
        self.remoteToken = RemoteAccessToken(defaults: defaults)
        load()
    }

    /// Registers a new subscriber for the coalesced workspace change signal. The
    /// returned stream yields once per change to `projects`, `gitInfo`, `attention`,
    /// or `jobNames`, letting a caller (e.g. the remote control channel) push a
    /// fresh snapshot without polling. Call `cancelWorkspaceChanges(_:)` with the
    /// returned id when done to release the subscription.
    func workspaceChanges() -> (id: UUID, stream: AsyncStream<Void>) {
        let id = UUID()
        let stream = AsyncStream<Void> { continuation in
            changeSubscribers[id] = continuation
        }
        if !changeTrackingArmed { changeTrackingArmed = true; armChangeTracking() }
        return (id, stream)
    }

    /// Unregisters a subscription previously created by `workspaceChanges()`.
    func cancelWorkspaceChanges(_ id: UUID) {
        changeSubscribers[id]?.finish()
        changeSubscribers[id] = nil
    }

    /// Observes the store's own sidebar-relevant properties. `withObservationTracking`
    /// fires `onChange` once when any accessed property next mutates; re-arm to keep
    /// observing. This turns Observation into a broadcast signal without editing
    /// every mutation site.
    private func armChangeTracking() {
        withObservationTracking {
            _ = projects
            _ = gitInfo
            _ = attention
            _ = jobNames
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for continuation in self.changeSubscribers.values { continuation.yield(()) }
                if !self.changeSubscribers.isEmpty { self.armChangeTracking() } else { self.changeTrackingArmed = false }
            }
        }
    }

    func addProject(url: URL) {
        let standardized = url.standardizedFileURL
        guard !projects.contains(where: {
            $0.url.standardizedFileURL.path == standardized.path
        }) else { return }
        guard (try? standardized.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )) != nil else { return }
        projects.append(Project(url: standardized))
        save()
        guard let added = projects.last else { return }
        if ConfigFile.exists(in: added.url) {
            reconcileWithFile(added.id)
            startWatching(added)
        }
        startGitWatching(added)
    }

    /// Removes a workspace and everything the store keeps for it.
    ///
    /// Its terminals go the same way a row removed on its own does: left alone
    /// where the user can still reach them, closed where this app was the only way
    /// to. See `releaseOrphaned`. Removing a workspace is the worse case of the two,
    /// because it takes every row at once.
    func remove(_ project: Project) {
        let terminalIds = project.terminals.map(\.id)
        // From the stored copy, not from the argument: a view holding a `Project`
        // from before a terminal opened would name a row with no session id and
        // orphan the terminal that row had by then acquired.
        let rows = projects.first(where: { $0.id == project.id })?.terminals ?? project.terminals
        releaseOrphaned(rows.map(\.sessionId))
        projects.removeAll { $0.id == project.id }
        gitInfo[project.id] = nil
        for id in terminalIds {
            attention.remove(id)
            jobNames[id] = nil
        }
        stopWatching(project.id)
        stopGitWatching(project.id)
        processes.removeWorkspace(project.id)
        testSupervisor.removeWorkspace(project.id)
        lastConfigData[project.id] = nil
        configChangedOnDisk.remove(project.id)
        schedule.forget(projectId: project.id)
        ownerRepo[project.id] = nil
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        projects.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func move(id: UUID, before targetId: UUID) {
        guard id != targetId,
              let from = projects.firstIndex(where: { $0.id == id }),
              projects.contains(where: { $0.id == targetId }) else { return }
        let item = projects.remove(at: from)
        guard let insertAt = projects.firstIndex(where: { $0.id == targetId }) else { return }
        projects.insert(item, at: insertAt)
        save()
    }

    func moveToEnd(id: UUID) {
        guard let from = projects.firstIndex(where: { $0.id == id }),
              from != projects.count - 1 else { return }
        let item = projects.remove(at: from)
        projects.append(item)
        save()
    }

    func openTerminal(for project: Project) async {
        await openSession(for: project, command: nil, kind: .terminal)
    }

    func openClaude(for project: Project) async {
        await openSession(for: project, command: "claude", kind: .claude)
    }

    /// The one way a row is ever started: a plain shell, with the row's command
    /// typed into it.
    ///
    /// Every path goes through here (opening a row, clicking one whose terminal is
    /// gone, restarting one) because they were three copies of the same three
    /// lines and the copies drifted. Fixing only the first left clicking a dead
    /// agent row broken, which is the common case rather than the rare one.
    ///
    /// Never `service.open(command:)`, which makes the command BE the shell, and
    /// that is wrong twice. A shell running `-c` is not interactive, so it never
    /// reads `.zshrc`, which is where a normal setup puts its PATH additions: the
    /// agent was not found, the child exited 127 in milliseconds, the reap unlinked
    /// its relay socket, and the surface's helper reported "this terminal is gone"
    /// with nothing pointing at a PATH. And a command that exits takes its pty with
    /// it, leaving a dead surface; a shell outlives its command, so the row falls
    /// back to a prompt and can be used or restarted.
    ///
    /// The command is derived from the kind here rather than passed in, so no
    /// caller can hand one to `open` again.
    private func openShell(folder: URL, existingWindowId: String?, badge: String?,
                           kind: TerminalKind) async throws -> TerminalHandle {
        let handle = try await service.open(folder: folder, existingWindowId: existingWindowId,
                                            command: nil, badge: badge)
        if let command = Self.command(for: kind) {
            try await service.send(sessionId: handle.sessionId, text: command + "\n")
        }
        return handle
    }

    /// What a row of this kind types into its shell, and nil for a plain terminal,
    /// whose shell is the terminal.
    static func command(for kind: TerminalKind) -> String? {
        switch kind {
        case .terminal: return nil
        case .claude: return "claude"
        }
    }

    private func openSession(for project: Project, command: String?, kind: TerminalKind) async {
        do {
            _ = try await openSessionThrowing(for: project, command: command, kind: kind)
        } catch {
            lastError = (error as? TerminalError)?.errorDescription
                ?? (error as? StoreError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Opens a session and returns the new terminal ref, propagating failures
    /// instead of routing them to `lastError`. The UI paths use
    /// `openSession`; the MCP router uses this.
    @discardableResult
    func openSessionThrowing(for project: Project, command: String?, kind: TerminalKind) async throws -> TerminalRef {
        guard let preIndex = projects.firstIndex(where: { $0.id == project.id }) else {
            throw StoreError.unknownProject
        }
        let folder = projects[preIndex].url
        let existingWindowId = settleWorkspaceId(at: preIndex)
        let badge = showWorkspaceBadge ? projects[preIndex].name : nil
        let handle: TerminalHandle
        do {
            handle = try await openShell(folder: folder, existingWindowId: existingWindowId,
                                          badge: badge, kind: kind)
        } catch {
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
        }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else {
            throw StoreError.unknownProject
        }
        let label: String
        switch kind {
        case .terminal:
            projects[index].terminalSeq += 1
            label = "Terminal \(projects[index].terminalSeq)"
        case .claude:
            projects[index].claudeSeq += 1
            label = "Claude \(projects[index].claudeSeq)"
        }
        recordWorkspaceId(handle.windowId, at: index, openedWith: existingWindowId)
        let ref = TerminalRef(label: label, sessionId: handle.sessionId, kind: kind)
        projects[index].terminals.append(ref)
        save()
        emitConfig(for: projects[index].id)
        return ref
    }

    /// Focuses a tracked session by its session id. Throws
    /// `unknownSession` if no tracked terminal owns that id.
    @discardableResult
    func focus(sessionId: String) async throws -> FocusResult {
        guard let (p, t) = indexOfSession(sessionId) else { throw StoreError.unknownSession }
        let refId = projects[p].terminals[t].id
        attention.remove(refId)
        do {
            return try await service.focus(sessionId: sessionId)
        } catch {
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Closes a tracked session and drops its ref from the store.
    func closeSession(sessionId: String) async throws {
        guard let (p, t) = indexOfSession(sessionId) else { throw StoreError.unknownSession }
        let refId = projects[p].terminals[t].id
        do {
            try await service.close(sessionId: sessionId)
        } catch {
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
        }
        guard let (np, _) = indexOfSession(sessionId) else { return }
        projects[np].terminals.removeAll { $0.id == refId }
        attention.remove(refId)
        jobNames[refId] = nil
        localOnlyTerminals.remove(refId)
        save()
        emitConfig(for: projects[np].id)
    }

    func activate(_ ref: TerminalRef, in project: Project) async {
        guard let prePIndex = projects.firstIndex(where: { $0.id == project.id }),
              let preTIndex = projects[prePIndex].terminals.firstIndex(where: { $0.id == ref.id }) else { return }
        let sessionId = projects[prePIndex].terminals[preTIndex].sessionId
        let kind = projects[prePIndex].terminals[preTIndex].kind
        let folder = projects[prePIndex].url
        let existingWindowId = settleWorkspaceId(at: prePIndex)
        let badge = showWorkspaceBadge ? projects[prePIndex].name : nil
        attention.remove(ref.id)
        do {
            // A row imported from config carries no session id until it is opened
            // once, and there is nothing to focus in that case. The check is here
            // rather than in the service because the empty id is a property of the
            // stored row, not of any one service.
            let result = sessionId.isEmpty
                ? FocusResult(found: false, jobName: nil)
                : try await service.focus(sessionId: sessionId)
            if result.found {
                // Live session: if it's a Claude row but claude is no longer
                // the foreground job (shell prompt / None jobName), re-run it.
                // `jobKnown` gates this: an unanswered job query is not evidence
                // the agent stopped, and acting on it types `claude` into a
                // running agent, which submits it as a prompt.
                if kind == .claude, result.jobKnown, !claudeIsRunning(jobName: result.jobName) {
                    try await service.send(sessionId: sessionId, text: "claude\n")
                }
            } else {
                // Whatever the service still holds under the old id goes first.
                // On both other substrates that is nothing: the session is gone,
                // which is what `focus` just said. The libghostty substrate keeps a
                // dead terminal's surface so its last screen stays readable, and
                // this reopen is the moment that screen is finished with; without
                // this the row would trade a dead terminal for a leaked surface and
                // NSView on every revival.
                if !sessionId.isEmpty { await service.discard(sessionId: sessionId) }
                let handle = try await openShell(folder: folder, existingWindowId: existingWindowId,
                                                  badge: badge, kind: kind)
                guard let pIndex = projects.firstIndex(where: { $0.id == project.id }),
                      let tIndex = projects[pIndex].terminals.firstIndex(where: { $0.id == ref.id }) else { return }
                // The pane id is recorded either way: a rename moves a session's
                // name, never its panes, so the row's new pane is real under
                // whatever the session is called now.
                recordWorkspaceId(handle.windowId, at: pIndex, openedWith: existingWindowId)
                projects[pIndex].terminals[tIndex].sessionId = handle.sessionId
                save()
            }
        } catch {
            lastError = (error as? TerminalError)?.errorDescription ?? error.localizedDescription
        }
    }

    func handle(_ event: MonitorEvent) {
        switch event {
        case .title(let sessionId, let name):
            guard let (p, t) = indexOfSession(sessionId) else { return }
            // A title equal to this workspace's badge is not a real title: with
            // "show workspace name as pane title" on, `TmuxService.open`/
            // `activate`/`restart` pass that same name as the badge, so a title
            // equal to it is the badge coming back rather than the agent reporting
            // one. Relabelling from it would flip a Claude row's label to the
            // workspace name the instant the terminal opens. The price is that an
            // agent that really did report its workspace's name is ignored, which is
            // indistinguishable from the badge and much rarer.
            if projects[p].terminals[t].kind == .claude, !name.isEmpty,
               name != projects[p].name,
               projects[p].terminals[t].label != name {
                projects[p].terminals[t].label = name
                save()
            }
        case .bell(let sessionId):
            guard let (p, t) = indexOfSession(sessionId) else { return }
            // Only the transition is reported. `insert` says whether the flag was
            // already up, and a row that is already asking for attention has nothing
            // new to announce: the notification for it is still in Notification
            // Center, and re-posting would replace it with an identical copy for
            // every beep an ambiguous tab completion makes.
            if attention.insert(projects[p].terminals[t].id).inserted {
                onBell?(projects[p], projects[p].terminals[t])
            }
        case .job(let sessionId, let jobName):
            guard let (p, t) = indexOfSession(sessionId) else { return }
            jobNames[projects[p].terminals[t].id] = jobName
        case .terminated(let sessionId):
            guard let (p, t) = indexOfSession(sessionId) else { return }
            jobNames[projects[p].terminals[t].id] = ""
        }
    }

    /// Claude counts as running when the foreground job is a non-empty,
    /// non-shell name.
    ///
    /// The job is the terminal's foreground command, read by the job poll and by
    /// `focus`, so a terminal running an agent reports that process's name and an
    /// idle one reports its shell. An empty string is a terminal that was answered
    /// for but gave no command, which is why it is not "running";
    /// a query that could not be answered at all is a different thing and never
    /// reaches here, see `FocusResult.jobKnown`.
    func claudeIsRunning(jobName: String?) -> Bool {
        guard let job = jobName, !job.isEmpty else { return false }
        return !isShell(job)
    }

    func runState(for ref: TerminalRef) -> ClaudeRunState {
        // No job info yet (monitor inactive or event not arrived): stay
        // optimistic so rows don't all read "exited" when monitoring is off.
        guard let job = jobNames[ref.id] else { return .running }
        return claudeIsRunning(jobName: job) ? .running : .exited
    }

    /// The workspace and row with this row id.
    ///
    /// By row id rather than session id because it answers a notification tap, and a
    /// notification can outlive the session it was posted about: a terminal restarted
    /// in the meantime keeps its row and gets a new session. The row is what the tap
    /// wants, and `activate` reopens whatever is no longer running.
    func session(withRefId refId: UUID) -> (project: Project, ref: TerminalRef)? {
        for project in projects {
            if let ref = project.terminals.first(where: { $0.id == refId }) {
                return (project, ref)
            }
        }
        return nil
    }

    func clearAttention(_ ref: TerminalRef) {
        attention.remove(ref.id)
    }

    /// An empty id matches nothing. Rows that have never opened all carry one,
    /// so a lookup by empty id would answer with whichever paneless row happens
    /// to come first.
    private func indexOfSession(_ sessionId: String) -> (Int, Int)? {
        guard !sessionId.isEmpty else { return nil }
        for (p, project) in projects.enumerated() {
            if let t = project.terminals.firstIndex(where: { $0.sessionId == sessionId }) {
                return (p, t)
            }
        }
        return nil
    }

    /// The workspace and row owning a session, for the callers that hold a session
    /// id and nothing else.
    func terminal(paneId: String) -> (project: Project, ref: TerminalRef)? {
        guard let (p, t) = indexOfSession(paneId) else { return nil }
        return (projects[p], projects[p].terminals[t])
    }

    /// The pane a row points at right now, or nil when it points at none.
    /// `activate` replaces the pane id when the old pane was gone, so a caller
    /// holding a `TerminalRef` from before that call must read the id back
    /// instead of reusing the stale one.
    ///
    /// A row that failed to open keeps its empty id, and the in-app terminal
    /// window is keyed by pane id alone, so returning that empty id opened a
    /// window nothing could ever stream to: an empty grid and a cursor.
    func currentPaneId(of ref: TerminalRef) -> String? {
        for project in projects {
            if let match = project.terminals.first(where: { $0.id == ref.id }) {
                return match.sessionId.isEmpty ? nil : match.sessionId
            }
        }
        return nil
    }

    /// The workspace id the next terminal opens into.
    ///
    /// Whatever is stored, and nothing else happens. There is no workspace object
    /// anywhere to name: a terminal is a PTY this process spawns, so there is
    /// nothing to derive, nothing to bring up before an open, and nothing that can
    /// belong to something else.
    ///
    /// It stays a stored value rather than being dropped because an id written by
    /// an older build is harmless and `open` ignores it, and because a workspace's
    /// own name is a separate thing that the user can change.
    @discardableResult
    private func settleWorkspaceId(at index: Int) -> String? {
        projects[index].windowId
    }

    /// Stores the workspace id `open` reported, unless the stored one moved while
    /// that call was in flight.
    ///
    /// `TerminalService` is nonisolated and `Sendable`, so `await service.open`
    /// leaves the main actor for the whole of the call, and anything that changed
    /// the stored id in that window would be overwritten by an unconditional write
    /// back. Nothing changes it today, so both sides are the same unchanged value
    /// and a workspace opening its first terminal compares nil against nil. The
    /// guard stays because the hazard is a property of the await, not of who
    /// currently writes.
    private func recordWorkspaceId(_ reported: String?, at index: Int, openedWith expected: String?) {
        guard projects[index].windowId == expected else { return }
        projects[index].windowId = reported
    }

    /// Clears every stored session id that cannot have survived, and reports how
    /// many rows were cleared.
    ///
    /// A terminal is a PTY this process spawned, so quitting ends it. Every id the
    /// app minted therefore names nothing on the next launch, and a row still
    /// carrying one would look running, refuse to reopen on a tap, and offer an
    /// attach that resolves to nothing.
    ///
    /// An id this build could not have minted is left exactly as it is. Those are
    /// leftovers from a launch on a substrate this app no longer has, and they cost
    /// nothing: `activate` asks the service to focus one, is told it is gone, and
    /// opens a real terminal in its place. Rewriting them would be work with no
    /// visible effect.
    ///
    /// The rows themselves survive. A row outliving its terminal is the model
    /// everywhere else in the app, and dropping them instead would empty every
    /// workspace on every launch.
    ///
    /// Not reported to the user. Nothing is lost that they did not choose by
    /// quitting, and it happens on every single launch, so a notice each time would
    /// be noise rather than news.
    ///
    /// Stored `windowId`s are untouched: nothing reads them.
    ///
    /// A no-op after the first call in this process: see
    /// `deadSessionsClearedThisLaunch`.
    @discardableResult
    func clearDeadSessions() -> Int {
        guard !deadSessionsClearedThisLaunch else { return 0 }
        deadSessionsClearedThisLaunch = true
        var cleared = 0
        for projectIndex in projects.indices {
            for terminalIndex in projects[projectIndex].terminals.indices {
                let sessionId = projects[projectIndex].terminals[terminalIndex].sessionId
                // An empty id is a row that was never opened, and an id without the
                // prefix was minted by a build this one replaced. `GhosttyService`
                // owns the prefix and the `open` that mints it, so this reads the
                // one definition rather than repeating it.
                guard !sessionId.isEmpty,
                      sessionId.hasPrefix(GhosttyService.sessionPrefix) else { continue }
                projects[projectIndex].terminals[terminalIndex].sessionId = ""
                cleared += 1
            }
        }
        if cleared > 0 { save() }
        return cleared
    }

    /// Clears the side tables keyed by a terminal's id.
    private func forgetTerminal(_ refId: UUID) {
        attention.remove(refId)
        jobNames[refId] = nil
        localOnlyTerminals.remove(refId)
    }

    /// Gives a workspace its own name, or takes that name away again.
    ///
    /// An empty or blank name clears the override rather than storing one, which is
    /// the only way back to whatever the workspace would be called without it: the
    /// `name` in its `wietty.json` if it has one, otherwise its folder. The
    /// alert pre-fills the current name, so clearing the field is the obvious
    /// gesture for "undo this".
    ///
    /// Local only, on purpose. Writing the name into the workspace's committed
    /// config would change a file in the user's git working tree as a side effect
    /// of a rename, and would only work for workspaces that have such a file.
    func renameWorkspace(_ project: Project, to name: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let settled = trimmed.isEmpty ? nil : trimmed
        guard projects[index].displayName != settled else { return }
        projects[index].displayName = settled
        save()
    }

    func rename(_ ref: TerminalRef, in project: Project, to label: String) {
        guard let pIndex = projects.firstIndex(where: { $0.id == project.id }),
              let tIndex = projects[pIndex].terminals.firstIndex(where: { $0.id == ref.id }) else { return }
        projects[pIndex].terminals[tIndex].label = label
        if projects[pIndex].terminals[tIndex].kind == .terminal {
            projects[pIndex].terminals[tIndex].slot = label
        }
        save()
        emitConfig(for: projects[pIndex].id)
    }

    /// Drops a row and closes the terminal it named, because the row was the only
    /// way to reach it.
    ///
    /// "Remove" reads as "forget this row, leave its terminal alone", and there is
    /// nothing here for that to mean: a terminal is a PTY this process owns, so a
    /// row dropped without a close leaves a live shell, its pty, its socket file,
    /// its helper process and its surface running with nothing able to name any of
    /// them until the app quits. See `releaseOrphaned`.
    func removeTerminal(_ ref: TerminalRef, in project: Project) {
        guard let pIndex = projects.firstIndex(where: { $0.id == project.id }),
              let tIndex = projects[pIndex].terminals.firstIndex(where: { $0.id == ref.id })
        else { return }
        let sessionId = projects[pIndex].terminals[tIndex].sessionId
        projects[pIndex].terminals.remove(at: tIndex)
        forgetTerminal(ref.id)
        releaseOrphaned([sessionId])
        save()
        emitConfig(for: project.id)
    }

    /// Closes terminals whose rows are being dropped without a close, because the
    /// row was the only way left to reach them.
    ///
    /// The store records a session id nowhere but on its row, so a row removed
    /// without a close leaves a live shell, its pty, its socket file, its helper
    /// process and its libghostty surface running with no UI able to name any of
    /// them until the app quits. Unconditional now: a terminal is a PTY this
    /// process owns, so there is never anywhere else for the user to find it.
    ///
    /// Fire and forget, and it has to be: every caller is a synchronous UI action
    /// and the row is already gone from the sidebar, so there is nothing left for a
    /// failure to be reported against. Logged rather than raised for the same reason
    /// a failed keystroke is.
    private func releaseOrphaned(_ sessionIds: [String]) {
        let orphans = sessionIds.filter { !$0.isEmpty }
        guard !orphans.isEmpty else { return }
        let service = self.service
        Task {
            for sessionId in orphans {
                do {
                    try await service.close(sessionId: sessionId)
                } catch {
                    StoreLog.store.error("""
                        closing removed terminal \(sessionId, privacy: .public) failed: \
                        \(String(describing: error), privacy: .public)
                        """)
                }
            }
        }
    }

    func toggleCollapsed(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].collapsed.toggle()
        let nowExpanded = !projects[index].collapsed
        save()
        if nowExpanded {
            let id = project.id
            for kind in CheckKind.allCases { schedule.reset(ScheduleKey(projectId: id, kind: kind)) }
            schedule.reset(JobPoll.key)
            Task { await runDueChecks(now: Date()) }
        }
    }

    func closeTerminal(_ ref: TerminalRef, in project: Project) async {
        guard let prePIndex = projects.firstIndex(where: { $0.id == project.id }),
              let preTIndex = projects[prePIndex].terminals.firstIndex(where: { $0.id == ref.id }) else { return }
        let sessionId = projects[prePIndex].terminals[preTIndex].sessionId
        do {
            // Nothing to close for a row that was never opened; drop it anyway.
            if !sessionId.isEmpty {
                try await service.close(sessionId: sessionId)
            }
            guard let pIndex = projects.firstIndex(where: { $0.id == project.id }) else { return }
            projects[pIndex].terminals.removeAll { $0.id == ref.id }
            // The whole side table, not just `localOnlyTerminals`, which is what this
            // cleared before. Every other path that drops a row calls this
            // (`removeTerminal`, `dropTerminal`, removing a workspace), and the flags
            // left behind here were invisible only because the row they belonged to was
            // gone: a closed row's attention flag kept its bell notification in
            // Notification Center with nothing left to withdraw it.
            forgetTerminal(ref.id)
            save()
            emitConfig(for: project.id)
        } catch {
            lastError = (error as? TerminalError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - MCP helpers

    /// Sends raw text to a known session by its session id. Throws
    /// `unknownSession` if no tracked terminal owns that id.
    func sendText(_ text: String, toSessionId sessionId: String) async throws {
        guard indexOfSession(sessionId) != nil else { throw StoreError.unknownSession }
        do {
            try await service.send(sessionId: sessionId, text: text)
        } catch {
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Reads recent rendered output for a known session.
    func readOutput(sessionId: String, maxLines: Int) async throws -> String {
        guard indexOfSession(sessionId) != nil else { throw StoreError.unknownSession }
        do {
            return try await service.readOutput(sessionId: sessionId, maxLines: maxLines)
        } catch {
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Restarts a tracked session: closes the current session and opens a
    /// fresh one in the same window, re-running the kind's command (`claude`
    /// for claude rows). The terminal ref keeps its id, label, and kind; its
    /// `sessionId` is updated to the new session. Returns the updated ref.
    @discardableResult
    func restart(sessionId: String) async throws -> TerminalRef {
        guard let (p, t) = indexOfSession(sessionId) else { throw StoreError.unknownSession }
        let kind = projects[p].terminals[t].kind
        let folder = projects[p].url
        let existingWindowId = settleWorkspaceId(at: p)
        let badge = showWorkspaceBadge ? projects[p].name : nil
        do {
            try? await service.close(sessionId: sessionId)
            let handle = try await openShell(folder: folder, existingWindowId: existingWindowId,
                                              badge: badge, kind: kind)
            guard let (np, nt) = indexOfSession(sessionId) else { throw StoreError.unknownSession }
            let oldId = projects[np].terminals[nt].id
            recordWorkspaceId(handle.windowId, at: np, openedWith: existingWindowId)
            projects[np].terminals[nt].sessionId = handle.sessionId
            attention.remove(oldId)
            jobNames[oldId] = nil
            save()
            return projects[np].terminals[nt]
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// True when a workspace's CI checks have pending/running entries.
    private func ciPending(_ projectId: UUID) -> Bool {
        (gitInfo[projectId]?.checks?.pending ?? 0) > 0
    }

    /// Builds the (key, tier) candidates for one workspace from live context.
    private func candidates(for project: Project) -> [(key: ScheduleKey, tier: CheckTier)] {
        let collapsed = project.collapsed
        let attention = attention.contains(project.id)
        // `.jobNames` is app-wide: one `list-panes -a` serves every workspace,
        // so it is scheduled once in `runDueChecks` rather than per workspace.
        return CheckKind.allCases.filter { $0 != .jobNames }.map { kind in
            let tier = checkTier(for: kind, collapsed: collapsed,
                                 ciPending: ciPending(project.id), needsAttention: attention)
            return (ScheduleKey(projectId: project.id, kind: kind), tier)
        }
    }

    /// The testable core of the scheduler: run every check that is due at `now`.
    func runDueChecks(now: Date) async {
        var all = projects.flatMap { candidates(for: $0) }
        // Always: libghostty reports a terminal's title and its bell but nothing
        // about its foreground command, so the job name has to be asked for.
        all.append((JobPoll.key,
                    JobPoll.tier(anyExpanded: projects.contains { !$0.collapsed })))
        let due = schedule.due(candidates: all, intervals: checkIntervals, now: now)
        // Record now up front so a slow check does not immediately re-fire next tick.
        for key in due { schedule.record(key, at: now) }
        for key in due { await run(key) }
    }

    /// Runs a single check and merges its slice into gitInfo (or process status).
    private func run(_ key: ScheduleKey) async {
        // The job poll belongs to no workspace, so it runs before the lookup.
        if key.kind == .jobNames {
            for event in jobEvents() { handle(event) }
            return
        }
        guard let url = projects.first(where: { $0.id == key.projectId })?.url else { return }
        switch key.kind {
        case .jobNames: return      // handled above; the switch has to be exhaustive
        case .gitSync:
            guard let sync = await gitProvider.gitSync(for: url) else { gitInfo[key.projectId] = nil; return }
            ownerRepo[key.projectId] = (sync.owner, sync.repo)
            var info = gitInfo[key.projectId] ?? GitInfo(
                branch: "", behind: 0, ahead: 0, hasUpstream: false,
                upstreamRef: nil, baseAhead: 0, baseBehind: 0, hasBase: false, baseRef: nil,
                issueNumber: nil, prNumber: nil, issueURL: nil, prURL: nil, checks: nil
            )
            info.branch = sync.branch
            info.behind = sync.behind; info.ahead = sync.ahead; info.hasUpstream = sync.hasUpstream; info.upstreamRef = sync.upstreamRef
            info.baseAhead = sync.baseAhead; info.baseBehind = sync.baseBehind; info.hasBase = sync.hasBase; info.baseRef = sync.baseRef
            info.issueNumber = sync.issueNumber
            info.issueURL = Self.issueURL(owner: sync.owner, repo: sync.repo, issue: sync.issueNumber)
            info.prURL = Self.prURL(owner: sync.owner, repo: sync.repo, pr: info.prNumber)
            gitInfo[key.projectId] = info
        case .pullRequest:
            guard var info = gitInfo[key.projectId], !info.branch.isEmpty else { return }
            let pr = await gitProvider.pullRequestNumber(for: url, branch: info.branch)
            info.prNumber = pr
            let or = ownerRepo[key.projectId]
            info.prURL = Self.prURL(owner: or?.0, repo: or?.1, pr: pr)
            if pr == nil { info.checks = nil }
            gitInfo[key.projectId] = info
        case .ciChecks:
            guard var info = gitInfo[key.projectId], let pr = info.prNumber else { return }
            info.checks = await gitProvider.ciChecks(for: url, prNumber: pr)
            gitInfo[key.projectId] = info
        case .processStatus:
            processes.refreshStatusesForWorkspace(key.projectId)
        case .workingTree:
            guard let fingerprint = await gitProvider.workingTreeFingerprint(for: url) else { return }
            forwardWorkingTreeFingerprint(fingerprint, projectId: key.projectId)
        }
    }

    /// Forwards a freshly-computed working-tree fingerprint to the test
    /// supervisor, which stales any passing test whose baseline differs.
    func forwardWorkingTreeFingerprint(_ fingerprint: String, projectId: UUID) {
        testSupervisor.applyWorkingTreeFingerprint(fingerprint, projectId: projectId)
    }

    /// A local `.git` change (commit, checkout, branch edit) was observed by the
    /// watcher: mark the git-sync check due and run due checks now so branch and
    /// ahead/behind state update immediately instead of on the next poll. Only
    /// git-sync is poked; PR/CI stay on their poll cadence so frequent local
    /// commits do not trigger network lookups. A no-op for unknown workspaces.
    func gitDirDidChange(_ projectId: UUID, now: Date = Date()) async {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        schedule.reset(ScheduleKey(projectId: projectId, kind: .gitSync))
        await runDueChecks(now: now)
    }

    /// Manual/Instant "run everything now": resets every schedule key so all
    /// checks are due, then runs them.
    func refreshAllGitInfo() async {
        for project in projects {
            for kind in CheckKind.allCases { schedule.reset(ScheduleKey(projectId: project.id, kind: kind)) }
        }
        schedule.reset(JobPoll.key)
        await runDueChecks(now: Date())
    }

    static func issueURL(owner: String?, repo: String?, issue: Int?) -> URL? {
        guard let owner, let repo, let issue else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/issues/\(issue)")
    }
    static func prURL(owner: String?, repo: String?, pr: Int?) -> URL? {
        guard let owner, let repo, let pr else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(pr)")
    }

    /// The `WIETTY_*` variables exposed to a workspace's process commands.
    /// Workspace path and name are always present; git-derived values appear
    /// only when known (they lag a refresh and are absent for non-repos), so a
    /// command referencing one is blocked until its value is available (unless
    /// the process opts into `allow_empty_vars`).
    func processVariables(for projectId: UUID) -> [String: String] {
        guard let project = projects.first(where: { $0.id == projectId }) else { return [:] }
        var vars: [String: String] = [
            "WIETTY_WORKSPACE_PATH": project.url.path,
            "WIETTY_WORKSPACE_NAME": project.name,
        ]
        if let info = gitInfo[projectId] {
            if !info.branch.isEmpty { vars["WIETTY_BRANCH"] = info.branch }
            if let upstream = info.upstreamRef { vars["WIETTY_UPSTREAM"] = upstream }
            if let base = info.baseRef { vars["WIETTY_BASE_BRANCH"] = base }
            if let issue = info.issueNumber { vars["WIETTY_ISSUE_NUMBER"] = String(issue) }
            if let pr = info.prNumber { vars["WIETTY_PR_NUMBER"] = String(pr) }
        }
        if let (owner, repo) = ownerRepo[projectId] {
            if let owner { vars["WIETTY_OWNER"] = owner }
            if let repo { vars["WIETTY_REPO"] = repo }
        }
        return vars
    }

    func startPeriodicRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDueChecks(now: Date())
                let tick = await self?.checkIntervals.fast ?? 15
                try? await Task.sleep(nanoseconds: UInt64(tick) * 1_000_000_000)
            }
        }
    }

    // MARK: - Config sync

    func isSyncEnabled(_ project: Project) -> Bool {
        ConfigFile.exists(in: project.url)
    }

    /// Writes the workspace's current rows to a new `wietty.json`, turning
    /// sync on. Records the written bytes so the watcher ignores this write.
    func enableConfigSync(for project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let config = ConfigReconcile.config(
            from: projects[index].terminals,
            name: projects[index].configName,
            processes: projects[index].configProcesses,
            tests: projects[index].configTests,
            shellInit: projects[index].configShellInit
        )
        do {
            lastConfigData[project.id] = try ConfigFile.write(config, in: projects[index].url)
            startWatching(projects[index])
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Rewrites the config file to mirror the workspace's current rows, but only
    /// when sync is on and the content actually changed. Clears local-only marks
    /// for the rewritten rows (they are now present in the file again).
    private func emitConfig(for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let project = projects[index]
        guard ConfigFile.exists(in: project.url) else { return }
        let config = ConfigReconcile.config(
            from: project.terminals, name: project.configName, processes: project.configProcesses,
            tests: project.configTests, shellInit: project.configShellInit
        )
        guard let data = try? config.encoded() else { return }
        if lastConfigData[projectId] == data { return }
        do {
            lastConfigData[projectId] = try ConfigFile.write(config, in: project.url)
            localOnlyTerminals.subtract(project.terminals.map(\.id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reads the workspace config and applies it to the current rows, preserving
    /// live sessions and keeping running rows dropped by the file as local-only.
    /// No-op when the file is absent (sync off).
    @discardableResult
    func reconcileWithFile(_ projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let url = projects[index].url
        let config: WorkspaceConfig?
        do {
            config = try ConfigFile.read(in: url)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard let config else { return false }
        let result = ConfigReconcile.apply(config, to: projects[index].terminals)
        projects[index].terminals = result.terminals
        projects[index].configName = config.name
        projects[index].configProcesses = config.processes
        projects[index].configTests = config.tests
        projects[index].configShellInit = config.shellInit
        processes.apply(config, projectId: projectId, directory: url) { [weak self] in
            self?.processVariables(for: projectId) ?? [:]
        }
        testSupervisor.apply(config, projectId: projectId, directory: url) { [weak self] in
            self?.processVariables(for: projectId) ?? [:]
        }
        localOnlyTerminals.formUnion(result.localOnly)
        lastConfigData[projectId] = ConfigFile.rawData(in: url)
        save()
        return true
    }

    private func startWatching(_ project: Project) {
        guard watchers[project.id] == nil, ConfigFile.exists(in: project.url) else { return }
        let id = project.id
        let watcher = ConfigWatcher(folder: project.url) { [weak self] in
            self?.configFileDidChange(id)
        }
        watchers[id] = watcher
        watcher.start()
    }

    private func stopWatching(_ projectId: UUID) {
        watchers[projectId]?.stop()
        watchers[projectId] = nil
    }

    private func startGitWatching(_ project: Project) {
        guard gitWatchers[project.id] == nil else { return }
        let id = project.id
        let watcher = GitDirWatcher(workspace: project.url) { [weak self] in
            Task { await self?.gitDirDidChange(id) }
        }
        gitWatchers[id] = watcher
        watcher.start()
    }

    private func stopGitWatching(_ projectId: UUID) {
        gitWatchers[projectId]?.stop()
        gitWatchers[projectId] = nil
    }

    /// Watcher callback. If the file was deleted, forgets the last-seen bytes
    /// and clears the signal, but leaves the folder watcher armed so a later
    /// external re-create is still detected; otherwise raises the change
    /// signal when the on-disk bytes differ from what we last saw.
    func configFileDidChange(_ projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let url = projects[index].url
        guard ConfigFile.exists(in: url) else {
            lastConfigData[projectId] = nil
            configChangedOnDisk.remove(projectId)
            return
        }
        if ConfigFile.rawData(in: url) != lastConfigData[projectId] {
            configChangedOnDisk.insert(projectId)
        }
    }

    /// User applied a detected change: reconcile rows from the file and clear the
    /// signal.
    func applyConfigChanges(for project: Project) {
        if reconcileWithFile(project.id) {
            configChangedOnDisk.remove(project.id)
        }
    }

    private func load() {
        guard let dataArray = defaults.array(forKey: storageKey) as? [Data] else { return }
        let decoder = JSONDecoder()
        var loaded: [Project] = []
        for data in dataArray {
            guard let record = try? decoder.decode(StoredProject.self, from: data) else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmark, options: [],
                relativeTo: nil, bookmarkDataIsStale: &isStale
            ) else { continue }
            loaded.append(Project(
                id: record.id,
                url: url.standardizedFileURL,
                terminals: record.terminals,
                displayName: record.displayName,
                windowId: record.windowId,
                terminalSeq: record.terminalSeq,
                claudeSeq: record.claudeSeq,
                collapsed: record.collapsed
            ))
        }
        projects = loaded
        for project in projects {
            if ConfigFile.exists(in: project.url) {
                reconcileWithFile(project.id)
                startWatching(project)
            }
            startGitWatching(project)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        let dataArray: [Data] = projects.compactMap { project in
            guard let bookmark = try? project.url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            ) else { return nil }
            let record = StoredProject(
                id: project.id,
                bookmark: bookmark,
                terminals: project.terminals,
                terminalSeq: project.terminalSeq,
                claudeSeq: project.claudeSeq,
                displayName: project.displayName,
                windowId: project.windowId,
                collapsed: project.collapsed
            )
            return try? encoder.encode(record)
        }
        defaults.set(dataArray, forKey: storageKey)
    }
}
