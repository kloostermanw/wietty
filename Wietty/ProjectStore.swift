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
    /// The last freshness-check results per workspace, produced by the `.freshness`
    /// check. Drives the card's `!` marker and its detail popover. Absent or empty
    /// means nothing to show.
    private(set) var freshness: [UUID: [FreshnessResult]] = [:]
    /// Per-workspace freshness cache: the passing results a `watch` check remembers
    /// against its file's hash, so an unchanged file skips re-running the command.
    /// In memory only, like `freshness` itself, so it is rebuilt from launch.
    private var freshnessCache: [UUID: FreshnessCache] = [:]
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
    /// Called for every desktop notification a process asks for on a tracked row,
    /// including the second one on a row that is already flagged.
    ///
    /// Deliberately not the once-per-flag rule `onBell` uses. That rule exists
    /// because a shell rings the bell for ambiguous tab completion, so a bell is
    /// ambiguous by nature and a run of them says nothing new. An `OSC 9` is a
    /// program choosing to send words, and an agent that says "waiting for input"
    /// and then "build failed" has said two things; suppressing the second because
    /// the row had not been visited would lose the one that matters. Nothing stacks
    /// as a result: the identifier is per terminal, so the newer banner replaces the
    /// older one.
    var onNotification: ((Project, TerminalRef, _ title: String, _ body: String) -> Void)?
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

    /// The shell lines from each workspace's config file the user has agreed to run.
    ///
    /// Kept per workspace rather than globally, because agreeing to a line in a
    /// folder you trust is not agreeing to it everywhere. Lines rather than a hash of
    /// the file, so removing a row or renaming the workspace does not ask again: only
    /// a line nobody has seen can run something new. See `ConfigTrust`.
    private(set) var approvedCommands: [UUID: Set<String>] = [:] {
        didSet {
            guard approvedCommands != oldValue else { return }
            persistSettings()
        }
    }

    /// The file waiting to be agreed to, and what it wants to run. Nil when there is
    /// nothing to ask. Shown by `ContentView`.
    var pendingConfigApproval: ConfigApprovalRequest?

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
    private let configFile: WiettyConfigFile
    /// False when the config file was present but could not be read at launch, so the
    /// app must not write over it. Blocks `persistSettings` for the process's life;
    /// the next launch that reads the file cleanly clears the condition.
    private var settingsPersistable = true
    private let service: TerminalService
    private let gitProvider: GitInfoProviding
    private let freshProvider: FreshnessChecking
    let processes: ProcessSupervisor
    let testSupervisor: TestSupervisor
    // The old `UserDefaults` keys, read once during migration and then removed. Their
    // values now live in `~/.config/wietty/config`; see `SettingsKeys`.
    private let storageKey = "wietty.projects.bookmarks"
    private let badgeKey = "wietty.showWorkspaceBadge"
    private let bellSoundKey = "wietty.bellSound"
    private let intervalsKey = "wietty.checkIntervals"
    private let remoteEnabledKey = "wietty.remote.enabled"
    private let mcpPortKey = "wietty.mcpPort"
    private let remotePortKey = "wietty.remotePort"
    private let sidebarWidthKey = "wietty.sidebarWidth"
    private let agentsKey = "wietty.agents"
    private let approvedCommandsKey = "wietty.approvedCommands"

    /// Every old `UserDefaults` key this store migrated out of, cleared once the
    /// config file has been seeded so nothing reads them again. The remote token is a
    /// secret and is not managed here at all: `RemoteAccessToken` keeps it in
    /// `UserDefaults`, so it is neither in this list nor ever written to the file.
    private var migratedDefaultsKeys: [String] {
        [storageKey, badgeKey, bellSoundKey, intervalsKey, remoteEnabledKey,
         mcpPortKey, remotePortKey, sidebarWidthKey, agentsKey, approvedCommandsKey]
    }

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
            persistSettings()
        }
    }

    /// The sound every notification a terminal posts plays. Persisted, and applied
    /// to the next notification rather than needing a restart.
    var bellSound: BellSound {
        didSet {
            guard bellSound != oldValue else { return }
            persistSettings()
        }
    }

    /// Tier durations (seconds) for periodic checks. Clamped to valid ranges and
    /// persisted. Changing it takes effect on the next scheduler tick.
    var checkIntervals: CheckIntervals {
        didSet {
            let clamped = checkIntervals.clamped()
            if clamped != checkIntervals { checkIntervals = clamped; return } // re-enter with clamped value
            guard checkIntervals != oldValue else { return }
            persistSettings()
        }
    }

    /// Whether the opt-in LAN remote terminal server runs. Off by default and
    /// persisted. `ContentView` starts/stops `RemoteServer` in response.
    var remoteEnabled: Bool {
        didSet {
            guard remoteEnabled != oldValue else { return }
            persistSettings()
        }
    }

    /// Port for the loopback MCP server. Clamped to `portRange` and persisted.
    /// Changing it takes effect when the MCP host is next (re)started.
    var mcpPort: Int {
        didSet {
            let clamped = Self.clampPort(mcpPort)
            if clamped != mcpPort { mcpPort = clamped; return }
            guard mcpPort != oldValue else { return }
            persistSettings()
        }
    }

    /// Port for the LAN remote terminal server. Clamped to `portRange` and
    /// persisted. Changing it takes effect when the server is next (re)started.
    var remotePort: Int {
        didSet {
            let clamped = Self.clampPort(remotePort)
            if clamped != remotePort { remotePort = clamped; return }
            guard remotePort != oldValue else { return }
            persistSettings()
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
            persistSettings()
        }
    }

    /// The sidebar's own colours, each optional (nil leaves the default). Persisted
    /// as `color-*` scalar keys; the terminal's colours are separate and live in
    /// `ghostty.cfg` (`GhosttyColorSettings`) because only libghostty can apply them.
    var sidebarColors: SidebarColors {
        didSet {
            guard sidebarColors != oldValue else { return }
            persistSettings()
        }
    }

    /// The agents a workspace's context menu offers, in menu order. A preference
    /// like the ports and the bell sound: persisted, and edited in the Agents tab.
    ///
    /// Seeded with Claude on a fresh install and never reseeded after that, so
    /// deleting the last entry sticks. See `loadAgents`.
    var agents: [AgentDefinition] {
        didSet {
            guard agents != oldValue else { return }
            // Reported rather than dropped on failure (see `persistSettings`): silence
            // leaves the list on screen and the list on disk disagreeing, with the
            // agent the user just added present in the menu now and gone next launch.
            persistSettings()
        }
    }

    /// Appends an agent to the end of the menu.
    func addAgent(_ agent: AgentDefinition) {
        agents.append(agent)
    }

    /// Reorders the agent menu (the Settings › Agents list is draggable).
    func moveAgent(fromOffsets: IndexSet, toOffset: Int) {
        agents.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Replaces the agent with the same id, and does nothing when there is none:
    /// the edit form is on screen while the list can change under it, and an edit
    /// of a deleted agent must not put it back.
    func updateAgent(_ agent: AgentDefinition) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index] = agent
    }

    func removeAgent(id: UUID) {
        agents.removeAll { $0.id == id }
    }

    /// The groups a workspace can be filed under, in the order they are shown. A
    /// machine-local preference like the agents: persisted, and edited in Settings ›
    /// General. Empty on a fresh install and never seeded, so the sidebar shows every
    /// workspace until the user makes a group.
    var groups: [WorkspaceGroup] {
        didSet {
            guard groups != oldValue else { return }
            persistSettings()
        }
    }

    /// The group whose workspaces the sidebar is showing, or nil for "All". Persisted
    /// so the choice survives a relaunch; resolved against `groups` on load so an id
    /// no group answers to reads as "All".
    var selectedGroupId: UUID? {
        didSet {
            guard selectedGroupId != oldValue else { return }
            persistSettings()
        }
    }

    /// Appends a group to the end of the list.
    func addGroup(_ group: WorkspaceGroup) {
        groups.append(group)
    }

    /// Reorders the group list (the Settings › General list is draggable).
    func moveGroup(fromOffsets: IndexSet, toOffset: Int) {
        groups.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Replaces the group with the same id, and does nothing when there is none: the
    /// Settings row is on screen while the list can change under it, and an edit of a
    /// deleted group must not put it back.
    func updateGroup(_ group: WorkspaceGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
    }

    /// Removes a group and unfiles every workspace that was in it, so no workspace
    /// keeps an id no group answers to. Clears the active selection too when it was
    /// this group, rather than filtering every workspace away against one that is gone.
    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        for index in projects.indices where projects[index].groupId == id {
            projects[index].groupId = nil
        }
        if selectedGroupId == id { selectedGroupId = nil }
        save()
    }

    /// Files a workspace under a group, or unfiles it when `groupId` is nil.
    func assignGroup(_ project: Project, to groupId: UUID?) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        guard projects[index].groupId != groupId else { return }
        projects[index].groupId = groupId
        save()
    }

    /// The stored list, or the seed when nothing has ever been stored.
    ///
    /// The distinction matters: seeding on an empty list rather than on an absent
    /// key would put Claude back on the launch after the last entry was deleted,
    /// which reads as a delete that did not work. An unreadable list is stored data
    /// too, so it is not the seed either: reseeding there hands back an agent the
    /// user did not ask for and the next edit writes it over what was stored.
    ///
    /// Entry by entry, so one bad entry costs that entry rather than the list, and
    /// only entries that could actually start something are kept.
    private static func loadAgents(_ defaults: UserDefaults, key: String) -> [AgentDefinition] {
        guard let data = defaults.data(forKey: key) else { return [.claude] }
        let stored = (try? JSONDecoder().decode([FailableAgentDefinition].self, from: data)) ?? []
        return stored.compactMap(\.agent).filter(\.isValid)
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

    /// The old workspace record, kept only to decode what earlier builds wrote to
    /// `UserDefaults` so it can be migrated into the config file. Nothing encodes it
    /// anymore; it is `Decodable`, not `Codable`.
    private struct StoredProject: Decodable {
        let id: UUID
        let bookmark: Data
        let terminals: [TerminalRef]
        let terminalSeq: Int
        let claudeSeq: Int
        let displayName: String?
        let windowId: String?
        let collapsed: Bool

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

    /// Where the user-facing settings live now, keyed to `defaults` so isolation
    /// carries over. Production hands the standard defaults and gets the real file at
    /// `~/.config/wietty/config`; a test that isolates its defaults gets a config file
    /// isolated the same way, so two stores built with one defaults share one file
    /// (settings-round-trip tests rely on that), and two built with different defaults
    /// do not.
    ///
    /// The isolation directory is stamped into `defaults` on first use, not derived
    /// from the instance's address: a freed `UserDefaults` can be reallocated at the
    /// same address, so an address-derived path would let one test read the file
    /// another test left behind. A stored id is unique per suite and stable for as
    /// long as that suite exists.
    private static func defaultConfig(for defaults: UserDefaults) -> WiettyConfigFile {
        guard defaults !== UserDefaults.standard else { return WiettyConfigFile() }
        let markerKey = "wietty.isolatedConfigDir"
        let id = defaults.string(forKey: markerKey) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: markerKey)
            return fresh
        }()
        return WiettyConfigFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("wietty-settings-\(id)/config"))
    }

    init(
        defaults: UserDefaults = .standard,
        config: WiettyConfigFile? = nil,
        service: TerminalService,
        jobEvents: @escaping @MainActor () -> [MonitorEvent] = { [] },
        gitProvider: GitInfoProviding = GitInfoService(),
        freshProvider: FreshnessChecking = FreshnessService(),
        processSupervisor: ProcessSupervisor = ProcessSupervisor(),
        testSupervisor: TestSupervisor = TestSupervisor()
    ) {
        self.defaults = defaults
        self.configFile = config ?? Self.defaultConfig(for: defaults)
        self.service = service
        self.jobEvents = jobEvents
        self.gitProvider = gitProvider
        self.freshProvider = freshProvider
        self.processes = processSupervisor
        self.testSupervisor = testSupervisor
        // The secret stays in `UserDefaults`; the config file never holds it.
        self.remoteToken = RemoteAccessToken(defaults: defaults)

        // The file is the source of truth once it exists. Its absence means the first
        // launch since settings moved here (or a fresh install, or the user deleted
        // it), and only then are the old `UserDefaults` keys read, to migrate them.
        //
        // A read that throws is a file that is present but unreadable (bad encoding, a
        // partial write, a permission change). It is treated as neither of those: the
        // settings load as their defaults so the app still opens, but nothing is
        // migrated over it and nothing is written back (`settingsPersistable` stays
        // false), so a corrupt or half-written file is left for the user to fix rather
        // than silently overwritten with defaults, taking every workspace with it.
        let fileExisted = FileManager.default.fileExists(atPath: configFile.url.path)
        let cfg: [String: String]
        let readError: Error?
        do {
            cfg = try configFile.read()
            readError = nil
        } catch {
            cfg = [:]
            readError = error
        }
        // Read from the file (empty means defaults) whenever there is a file, readable
        // or not; migrate from `UserDefaults` only when there is genuinely no file.
        let migrating = !fileExisted && readError == nil

        if !migrating {
            self.showWorkspaceBadge = cfg[SettingsKeys.showWorkspaceBadge] == "true"
            self.bellSound = BellSound(stored: cfg[SettingsKeys.bellSound] ?? "")
            self.checkIntervals = Self.intervals(from: cfg)
            self.remoteEnabled = cfg[SettingsKeys.remoteEnabled] == "true"
            self.mcpPort = Self.port(cfg[SettingsKeys.mcpPort], default: MCPServerHost.defaultPort)
            self.remotePort = Self.port(cfg[SettingsKeys.remotePort], default: RemoteServer.defaultPort)
            self.sidebarWidth = Self.width(cfg[SettingsKeys.sidebarWidth])
            self.sidebarColors = SidebarColors(from: cfg)
            self.agents = Self.agents(from: cfg)
            self.approvedCommands = Self.approvals(from: cfg)
            let loadedGroups = Self.groups(from: cfg)
            self.groups = loadedGroups
            self.selectedGroupId = Self.selectedGroup(from: cfg, groups: loadedGroups)
        } else {
            self.showWorkspaceBadge = defaults.bool(forKey: badgeKey)
            // No stored value reads as "", which `BellSound` maps to the system
            // default: the sound this app played before there was a setting.
            self.bellSound = BellSound(stored: defaults.string(forKey: bellSoundKey) ?? "")
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
            // Colours are new with the file: no build wrote them to `UserDefaults`,
            // so a migrating install starts with none and keeps the defaults.
            self.sidebarColors = SidebarColors()
            self.agents = Self.loadAgents(defaults, key: agentsKey)
            let storedApprovals = defaults.dictionary(forKey: approvedCommandsKey) as? [String: [String]] ?? [:]
            self.approvedCommands = storedApprovals.reduce(into: [UUID: Set<String>]()) {
                guard let id = UUID(uuidString: $1.key) else { return }
                $0[id] = Set($1.value)
            }
            // Groups arrive with the config file: no build wrote them to `UserDefaults`,
            // so a migrating install starts with none and no active group.
            self.groups = []
            self.selectedGroupId = nil
        }

        // Loads workspaces (from the file, or by migrating the old bookmarks) and
        // reconciles every one that has a `wietty.json`, which needs the approvals
        // read just above.
        load(cfg: cfg, migrating: migrating)

        if let readError {
            // Present but unreadable: refuse to write until the next launch reads it
            // cleanly, and say so. `lastError` is the store's usual channel and is
            // shown as an alert by `ContentView`.
            settingsPersistable = false
            lastError = "Could not read \(configFile.url.path): \(readError.localizedDescription). "
                + "The file was left untouched; fix or remove it, then relaunch."
        } else if migrating {
            // Seed the file from the migrated values on the first launch, then drop the
            // old keys so nothing reads them again. Done after `load()` so the seed
            // write includes the workspaces it just migrated. The keys are removed only
            // if that write succeeded: a failed seed must stay repeatable, not destroy
            // the only remaining copy.
            if persistSettings() {
                for key in migratedDefaultsKeys { defaults.removeObject(forKey: key) }
            }
        }
    }

    // MARK: - Reading settings from the config file

    private static func intervals(from cfg: [String: String]) -> CheckIntervals {
        guard let f = cfg[SettingsKeys.checkIntervalFast].flatMap(Int.init),
              let n = cfg[SettingsKeys.checkIntervalNormal].flatMap(Int.init),
              let s = cfg[SettingsKeys.checkIntervalSlow].flatMap(Int.init) else { return .default }
        return CheckIntervals(fast: f, normal: n, slow: s).clamped()
    }

    private static func port(_ value: String?, default fallback: Int) -> Int {
        guard let value, let port = Int(value), port != 0 else { return fallback }
        return clampPort(port)
    }

    private static func width(_ value: String?) -> Double {
        guard let value, let width = Double(value), width != 0 else { return SidebarWidth.default }
        return max(width, SidebarWidth.minimum)
    }

    /// The `agent.N.*` entries, in index order, keeping only the ones that could
    /// actually start something (`isValid`). No seed here: a file that exists is a
    /// full snapshot, so no agents means the list is empty on purpose. Seeding only
    /// happens when migrating, via `loadAgents`.
    private static func agents(from cfg: [String: String]) -> [AgentDefinition] {
        var result: [AgentDefinition] = []
        var index = 0
        while let name = cfg["\(SettingsKeys.agentPrefix)\(index).name"] {
            let agent = AgentDefinition(
                name: name,
                command: cfg["\(SettingsKeys.agentPrefix)\(index).command"] ?? "",
                defaultArguments: cfg["\(SettingsKeys.agentPrefix)\(index).args"] ?? ""
            )
            if agent.isValid { result.append(agent) }
            index += 1
        }
        return result
    }

    /// The `group.N.*` entries, in index order, keeping only the ones with a name to
    /// show. Like the agents, no seed: a file that exists is a full snapshot, so no
    /// entries means the list is empty on purpose.
    private static func groups(from cfg: [String: String]) -> [WorkspaceGroup] {
        var result: [WorkspaceGroup] = []
        var index = 0
        while let stored = cfg["\(SettingsKeys.groupPrefix)\(index).id"] {
            let name = cfg["\(SettingsKeys.groupPrefix)\(index).name"] ?? ""
            index += 1
            // A group id is a cross-reference target: a workspace (`Project.groupId`)
            // and the active selection (`selected-group`) point at it. Minting a fresh
            // id for an unparseable one would silently detach every workspace filed
            // under it, so a malformed entry is dropped, the way a blank-named one is.
            guard let id = UUID(uuidString: stored) else { continue }
            let group = WorkspaceGroup(id: id, name: name)
            if group.isValid { result.append(group) }
        }
        return result
    }

    /// The stored active group, dropped to nil unless a group in `groups` still
    /// answers to it. A hand-edited file, or a group an older build removed, must not
    /// leave the sidebar filtering against an id nothing matches.
    private static func selectedGroup(from cfg: [String: String],
                                      groups: [WorkspaceGroup]) -> UUID? {
        guard let stored = cfg[SettingsKeys.selectedGroup].flatMap({ UUID(uuidString: $0) }),
              groups.contains(where: { $0.id == stored }) else { return nil }
        return stored
    }

    /// The `approved.<uuid>.N` entries, grouped back by workspace id. The key after
    /// the prefix is `<uuid>.<n>`, and a uuid has no dots, so the last dot splits the
    /// index off.
    private static func approvals(from cfg: [String: String]) -> [UUID: Set<String>] {
        var result: [UUID: Set<String>] = [:]
        for (key, value) in cfg where key.hasPrefix(SettingsKeys.approvedPrefix) {
            let rest = key.dropFirst(SettingsKeys.approvedPrefix.count)
            guard let dot = rest.lastIndex(of: "."),
                  let id = UUID(uuidString: String(rest[..<dot])) else { continue }
            result[id, default: []].insert(value)
        }
        return result
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
        freshness[project.id] = nil
        freshnessCache[project.id] = nil
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
        await openSession(for: project, kind: .terminal)
    }

    func openClaude(for project: Project) async {
        await openSession(for: project, kind: .claude)
    }

    /// Opens a row for one of the configured agents.
    ///
    /// An agent row in every other respect: same kind, same numbering, same glyph.
    /// What it carries of its own is the line to type, because that is the one thing
    /// the kind cannot answer once there is more than one agent.
    ///
    /// - Parameter arguments: what "Add Agent with args" collected, or nil for a
    ///   plain "Add Agent", which uses the agent's defaults.
    func openAgent(_ agent: AgentDefinition, arguments: String? = nil, for project: Project) async {
        await openSession(for: project, kind: .claude,
                          agent: (name: agent.displayName,
                                  line: agent.launchCommand(arguments: arguments)))
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
    /// The line is the row's own or the kind's, never a caller's, so no caller can
    /// hand one to `open` again.
    ///
    /// - Parameter command: the row's stored line (`TerminalRef.command`), or nil for
    ///   a row that runs whatever its kind runs.
    private func openShell(folder: URL, existingWindowId: String?, badge: String?,
                           kind: TerminalKind, command: String? = nil) async throws -> TerminalHandle {
        let handle = try await service.open(folder: folder, existingWindowId: existingWindowId,
                                            command: nil, badge: badge)
        if let line = command ?? Self.command(for: kind) {
            try await service.send(sessionId: handle.sessionId, text: line + "\n")
        }
        return handle
    }

    /// What a row types into its shell: its own line if it has one, else whatever
    /// its kind runs.
    static func command(for ref: TerminalRef) -> String? {
        ref.command ?? command(for: ref.kind)
    }

    /// What a row of this kind types into its shell, and nil for a plain terminal,
    /// whose shell is the terminal. Claude rather than an agent from the list: a row
    /// with no line of its own predates the list, or came from a `wietty.json`, and
    /// both of those are Claude rows.
    static func command(for kind: TerminalKind) -> String? {
        switch kind {
        case .terminal: return nil
        case .claude: return "claude"
        }
    }

    private func openSession(for project: Project, kind: TerminalKind,
                             agent: (name: String, line: String)? = nil) async {
        do {
            _ = try await openSessionThrowing(for: project, kind: kind, agent: agent)
        } catch {
            lastError = (error as? TerminalError)?.errorDescription
                ?? (error as? StoreError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Opens a session and returns the new terminal ref, propagating failures
    /// instead of routing them to `lastError`. The UI paths use
    /// `openSession`; the MCP router uses this.
    ///
    /// - Parameter agent: the entry from the agent list this row is for, if it came
    ///   from one: its name, which the label is built from, and the line it types.
    ///   Nil for a plain terminal and for the hardcoded Claude row.
    @discardableResult
    func openSessionThrowing(for project: Project, kind: TerminalKind,
                             agent: (name: String, line: String)? = nil) async throws -> TerminalRef {
        guard let preIndex = projects.firstIndex(where: { $0.id == project.id }) else {
            throw StoreError.unknownProject
        }
        let folder = projects[preIndex].url
        let existingWindowId = settleWorkspaceId(at: preIndex)
        let badge = showWorkspaceBadge ? projects[preIndex].name : nil
        let handle: TerminalHandle
        do {
            handle = try await openShell(folder: folder, existingWindowId: existingWindowId,
                                          badge: badge, kind: kind, command: agent?.line)
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
            // One counter for every agent, so two agents in a workspace are numbered
            // 1 and 2 rather than both 1. The name in front is what tells them apart.
            projects[index].claudeSeq += 1
            label = "\(agent?.name ?? "Claude") \(projects[index].claudeSeq)"
        }
        recordWorkspaceId(handle.windowId, at: index, openedWith: existingWindowId)
        let ref = TerminalRef(label: label, sessionId: handle.sessionId, kind: kind,
                              command: agent?.line)
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

    /// The window's entry point to activation, reporting rather than throwing.
    ///
    /// The same split `restart`/`restartTerminal` has, for the same reason: a click has
    /// nobody to answer, so it reports into `lastError` and the alert shows it, while
    /// the remote server turns the throw into a status for the viewer that asked.
    func activate(_ ref: TerminalRef, in project: Project) async {
        do {
            try await activateThrowing(ref, in: project)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func activateThrowing(_ ref: TerminalRef, in project: Project) async throws {
        guard let prePIndex = projects.firstIndex(where: { $0.id == project.id }),
              let preTIndex = projects[prePIndex].terminals.firstIndex(where: { $0.id == ref.id }) else { return }
        let sessionId = projects[prePIndex].terminals[preTIndex].sessionId
        let kind = projects[prePIndex].terminals[preTIndex].kind
        // The row's own line, so a reopen or a restart types what this row runs
        // rather than what its kind runs. Read from the store rather than from the
        // `ref` argument, which is a copy the caller may have been holding for a
        // while.
        let command = Self.command(for: projects[prePIndex].terminals[preTIndex])
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
                if kind == .claude, let command, result.jobKnown,
                   !claudeIsRunning(jobName: result.jobName) {
                    try await service.send(sessionId: sessionId, text: command + "\n")
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
                                                  badge: badge, kind: kind, command: command)
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
            throw StoreError.terminal((error as? TerminalError)?.errorDescription ?? error.localizedDescription)
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
            // A `fixed_naming` agent row keeps its slot and ignores the reported
            // title, which is the whole point of the flag: the row is pinned to its
            // configured name rather than following what the agent renames its tab to.
            if projects[p].terminals[t].kind == .claude, !name.isEmpty,
               !projects[p].terminals[t].fixedNaming,
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
        case .notification(let sessionId, let title, let body):
            guard let (p, t) = indexOfSession(sessionId) else { return }
            // The flag goes up the same way a bell raises it, so the 🔔 in the
            // sidebar means "this terminal wants you" whichever way it said so, and
            // visiting the row withdraws the banner through the same path. What is
            // reported is every notification rather than only the transition; see
            // `onNotification` for why the two rules differ.
            attention.insert(projects[p].terminals[t].id)
            onNotification?(projects[p], projects[p].terminals[t], title, body)
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

    /// Whether this row's terminal is running right now, used to tint its sidebar
    /// glyph green. Unlike `runState`, a row with no job info yet counts as not
    /// running rather than optimistically running, so a freshly launched app does
    /// not paint every row as active. A plain terminal is running whenever its
    /// shell is live (any non-empty job); an agent only while its foreground job is
    /// the agent rather than that shell. A terminated row reports an empty job.
    func isSessionRunning(_ ref: TerminalRef) -> Bool {
        guard let job = jobNames[ref.id], !job.isEmpty else { return false }
        return ref.kind == .claude ? claudeIsRunning(jobName: job) : true
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

    /// Drops a session's attention flag because the user is typing into it.
    ///
    /// The pane raises this on every keystroke into the surface it shows, which is
    /// the terminal the user is looking at and answering: a bell that rang while
    /// this app was in the background has been dealt with the moment they type, with
    /// no need to click the row first. By session id rather than row id because the
    /// surface knows only the session it renders. An untracked or empty id is a
    /// no-op, so a keystroke into a paneless or already closed session changes
    /// nothing.
    ///
    /// The `contains` guard is what makes this safe to call per keystroke: `attention`
    /// is observed, and mutating it at all wakes every view that reads it (the whole
    /// sidebar), so the common case of typing into a terminal with no bell pending
    /// must not touch the set. It is removed only when a flag is actually up, and the
    /// `didSet` then withdraws the banner.
    func clearAttention(sessionId: String) {
        guard let (p, t) = indexOfSession(sessionId) else { return }
        let id = projects[p].terminals[t].id
        guard attention.contains(id) else { return }
        attention.remove(id)
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

    /// Stops a row's running session without removing the row. Unlike
    /// `closeTerminal`, the terminal's last screen stays readable and the row remains
    /// so it can be reopened; the child is terminated and the row dims to exited. A
    /// no-op for a row that was never opened.
    func stopTerminal(_ ref: TerminalRef, in project: Project) async {
        guard let pIndex = projects.firstIndex(where: { $0.id == project.id }),
              let tIndex = projects[pIndex].terminals.firstIndex(where: { $0.id == ref.id }) else { return }
        let sessionId = projects[pIndex].terminals[tIndex].sessionId
        guard !sessionId.isEmpty else { return }
        await service.stop(sessionId: sessionId)
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
    /// fresh one in the same window, re-running the row's line (its own if it has
    /// one, else `claude` for an agent row and nothing for a terminal). The terminal
    /// ref keeps its id, label, kind, and line; its `sessionId` is updated to the new
    /// session. Returns the updated ref.
    @discardableResult
    func restart(sessionId: String) async throws -> TerminalRef {
        guard let (p, t) = indexOfSession(sessionId) else { throw StoreError.unknownSession }
        let kind = projects[p].terminals[t].kind
        let command = Self.command(for: projects[p].terminals[t])
        let folder = projects[p].url
        let existingWindowId = settleWorkspaceId(at: p)
        let badge = showWorkspaceBadge ? projects[p].name : nil
        do {
            // Propagated, not swallowed. A restart that could not stop the old
            // session has not restarted anything, and carrying on repoints the row at
            // the replacement, so the previous agent keeps running with its pty and
            // its write access to the folder and nothing left referencing it.
            try await service.close(sessionId: sessionId)
            let handle = try await openShell(folder: folder, existingWindowId: existingWindowId,
                                              badge: badge, kind: kind, command: command)
            guard let (np, nt) = indexOfSession(sessionId) else {
                // The row went away while the replacement was opening, so nothing will
                // ever point at the shell just opened. Closed here rather than left
                // running where no one can reach it. Best effort: the throw below is
                // the more useful thing to report.
                try? await service.close(sessionId: handle.sessionId)
                throw StoreError.unknownSession
            }
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

    /// The window's entry point to the same restart, reporting rather than throwing.
    ///
    /// `restart(sessionId:)` throws because the MCP server and the remote server turn
    /// its error into a response for whoever asked. A click has nobody to answer, so
    /// it reports into `lastError` and the alert shows it, which is what
    /// `openTerminal`, `activate` and `closeTerminal` already do for the same reason.
    /// Swallowing it instead left a restart that could not open its replacement
    /// looking like a restart that worked.
    func restartTerminal(sessionId: String) async {
        do {
            _ = try await restart(sessionId: sessionId)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            gitInfo[key.projectId] = info
        case .ciChecks:
            // Sole owner of `info.checks`: a PR sources it from `gh pr checks`,
            // and a PR-less pushed branch sources the same summary from the
            // branch head commit's checks (nil when there is neither).
            guard var info = gitInfo[key.projectId], !info.branch.isEmpty else { return }
            if let pr = info.prNumber {
                info.checks = await gitProvider.ciChecks(for: url, prNumber: pr)
            } else {
                info.checks = await gitProvider.ciChecks(for: url, branch: info.branch)
            }
            gitInfo[key.projectId] = info
        case .processStatus:
            processes.refreshStatusesForWorkspace(key.projectId)
        case .workingTree:
            guard let fingerprint = await gitProvider.workingTreeFingerprint(for: url) else { return }
            forwardWorkingTreeFingerprint(fingerprint, projectId: key.projectId)
        case .freshness:
            let checks = projects.first(where: { $0.id == key.projectId })?.configChecks ?? [:]
            // No checks configured means nothing to run and nothing to show, so the
            // slot is cleared rather than left holding a stale result. Only write when
            // there is something to clear, so a workspace with no checks does not churn
            // the observable dictionary on every tick.
            guard !checks.isEmpty else {
                if freshness[key.projectId] != nil { freshness[key.projectId] = nil }
                if freshnessCache[key.projectId] != nil { freshnessCache[key.projectId] = nil }
                return
            }
            let shellInit = projects.first(where: { $0.id == key.projectId })?.configShellInit ?? []
            let (results, cache) = await freshProvider.run(
                checks: checks, in: url, cache: freshnessCache[key.projectId] ?? [:], shellInit: shellInit)
            freshness[key.projectId] = results
            freshnessCache[key.projectId] = cache
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
                let tick = self?.checkIntervals.fast ?? 15
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
            checks: projects[index].configChecks,
            shellInit: projects[index].configShellInit
        )
        // Written from what this workspace is already running, so there is nothing
        // here the user has not already asked for. Approving it here is what keeps
        // turning sync on from immediately asking about the user's own rows.
        approve(ConfigTrust.commands(in: config), for: project.id)
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
            tests: project.configTests, checks: project.configChecks, shellInit: project.configShellInit
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

    /// Wording for a config file that could not be read. The alert shows
    /// `lastError` and nothing else, and the file watcher can raise one for a
    /// workspace the user is not looking at, so the folder has to be named here
    /// rather than left to the surrounding UI.
    private static func configFailure(_ error: Error, in folder: URL) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(folder.lastPathComponent): \(detail)"
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
            lastError = Self.configFailure(error, in: url)
            return false
        }
        guard let config else { return false }
        // Nothing from an unapproved file reaches the store: not the rows, not the
        // process definitions, and above all not an `auto_start` the supervisor would
        // run on the spot. Laying the rows out and waiting for a click would not be
        // enough, because a row's whole content is the line it types.
        if case .needed(let commands) = ConfigTrust.approval(
            for: config, approved: approvedCommands[projectId] ?? []
        ) {
            pendingConfigApproval = ConfigApprovalRequest(
                projectId: projectId, workspaceName: projects[index].name, commands: commands
            )
            return false
        }
        let result = ConfigReconcile.apply(config, to: projects[index].terminals)
        projects[index].terminals = result.terminals
        projects[index].configName = config.name
        projects[index].configProcesses = config.processes
        projects[index].configTests = config.tests
        projects[index].configChecks = config.checks
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

    /// Records lines as agreed to for one workspace.
    func approve(_ commands: [String], for projectId: UUID) {
        guard !commands.isEmpty else { return }
        approvedCommands[projectId, default: []].formUnion(commands)
    }

    // MARK: - Editing the workspace config from the Edit workspace page
    //
    // The methods below let the Edit workspace page change what a workspace's
    // `wietty.json` says: its `shell_init`, agents, terminals, processes and tests.
    // Each mutates the live `Project` and then routes through `commitConfigEdits`,
    // so a change typed on the page behaves exactly like the same change reconciled
    // from disk, minus the approval prompt: the user typing it here is the consent
    // the prompt would otherwise ask for, the same standing `enableConfigSync`
    // relies on.
    //
    // They assume sync is on, which the page enforces by showing an "Enable config
    // sync" button rather than the editors until it is. Only the file write is
    // actually guarded (`emitConfig` checks the file exists); the in-memory mutation
    // and the supervisor apply are not, so calling one with sync off would leave the
    // `Project` and the (absent) file out of step. That state is unreachable through
    // the UI, and these are the only callers.

    /// Rebuilds the config from the workspace's live state, agrees to every line it
    /// now runs, applies the process and test definitions to their supervisors, and
    /// rewrites the file. The one path every Edit-workspace mutator ends in.
    private func commitConfigEdits(for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let project = projects[index]
        let config = ConfigReconcile.config(
            from: project.terminals, name: project.configName, processes: project.configProcesses,
            tests: project.configTests, checks: project.configChecks, shellInit: project.configShellInit
        )
        // The edit is the user asking for it, so nothing here needs a second question.
        approve(ConfigTrust.commands(in: config), for: projectId)
        processes.apply(config, projectId: projectId, directory: project.url) { [weak self] in
            self?.processVariables(for: projectId) ?? [:]
        }
        testSupervisor.apply(config, projectId: projectId, directory: project.url) { [weak self] in
            self?.processVariables(for: projectId) ?? [:]
        }
        save()
        emitConfig(for: projectId)
    }

    /// Replaces the workspace-wide `shell_init` lines. Blank lines are dropped and
    /// an empty result is stored as absent, so the key leaves the file rather than
    /// lingering as `"shell_init": []`.
    func setShellInit(_ lines: [String], for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let settled: [String]? = kept.isEmpty ? nil : kept
        guard projects[index].configShellInit != settled else { return }
        projects[index].configShellInit = settled
        commitConfigEdits(for: projectId)
    }

    /// Adds a process definition under a new name. Refuses an empty name or one that
    /// is already taken, returning false so the add form can keep what the user
    /// typed rather than silently dropping it.
    @discardableResult
    func addProcess(name: String, config: ProcessConfig, for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var procs = projects[index].configProcesses ?? [:]
        guard procs[trimmed] == nil else { return false }
        procs[trimmed] = config
        projects[index].configProcesses = procs
        commitConfigEdits(for: projectId)
        return true
    }

    /// Applies an edit to an existing process row, renaming it when the name
    /// changed. Refuses an empty name, an unknown original, or a rename onto a
    /// different existing process; returns false so the row stays in edit mode.
    @discardableResult
    func updateProcess(originalName: String, name: String, config: ProcessConfig,
                       for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              var procs = projects[index].configProcesses, procs[originalName] != nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == originalName || procs[trimmed] == nil else { return false }
        procs[originalName] = nil
        procs[trimmed] = config
        projects[index].configProcesses = procs
        commitConfigEdits(for: projectId)
        return true
    }

    /// Removes a process definition. Clears the section to absent when it empties.
    func removeProcess(name: String, for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              var procs = projects[index].configProcesses, procs[name] != nil else { return }
        procs[name] = nil
        projects[index].configProcesses = procs.isEmpty ? nil : procs
        commitConfigEdits(for: projectId)
    }

    /// Adds a test definition under a new name. Same refusals as `addProcess`.
    @discardableResult
    func addTest(name: String, config: TestConfig, for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var tests = projects[index].configTests ?? [:]
        guard tests[trimmed] == nil else { return false }
        tests[trimmed] = config
        projects[index].configTests = tests
        commitConfigEdits(for: projectId)
        return true
    }

    /// Applies an edit to an existing test row, renaming it when the name changed.
    /// Same refusals as `updateProcess`.
    @discardableResult
    func updateTest(originalName: String, name: String, config: TestConfig,
                    for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              var tests = projects[index].configTests, tests[originalName] != nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == originalName || tests[trimmed] == nil else { return false }
        tests[originalName] = nil
        tests[trimmed] = config
        projects[index].configTests = tests
        commitConfigEdits(for: projectId)
        return true
    }

    /// Removes a test definition. Clears the section to absent when it empties.
    func removeTest(name: String, for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              var tests = projects[index].configTests, tests[name] != nil else { return }
        tests[name] = nil
        projects[index].configTests = tests.isEmpty ? nil : tests
        commitConfigEdits(for: projectId)
    }

    /// Adds a freshness-check definition under a new name. Same refusals as
    /// `addTest`: an empty name or one already taken is rejected so the add form
    /// keeps what the user typed.
    @discardableResult
    func addCheck(name: String, config: CheckConfig, for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var checks = projects[index].configChecks ?? [:]
        guard checks[trimmed] == nil else { return false }
        checks[trimmed] = config
        projects[index].configChecks = checks
        commitConfigEdits(for: projectId)
        return true
    }

    /// Applies an edit to an existing check row, renaming it when the name changed.
    /// Same refusals as `updateTest`.
    @discardableResult
    func updateCheck(originalName: String, name: String, config: CheckConfig,
                     for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              var checks = projects[index].configChecks, checks[originalName] != nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == originalName || checks[trimmed] == nil else { return false }
        checks[originalName] = nil
        checks[trimmed] = config
        projects[index].configChecks = checks
        commitConfigEdits(for: projectId)
        return true
    }

    /// Removes a check definition. Clears the section to absent when it empties, and
    /// drops any stored result for it so the marker does not keep asking for a check
    /// that no longer exists.
    func removeCheck(name: String, for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }),
              var checks = projects[index].configChecks, checks[name] != nil else { return }
        checks[name] = nil
        projects[index].configChecks = checks.isEmpty ? nil : checks
        freshness[projectId] = freshness[projectId]?.filter { $0.name != name }
        freshnessCache[projectId]?[name] = nil
        commitConfigEdits(for: projectId)
    }

    /// Adds a declared agent row: a row with no session yet, exactly what a
    /// `wietty.json` agent entry is. `type` is the line it runs (`claude` for the
    /// default). Refuses an empty slot or one already used by another agent row,
    /// since the file matches rows to entries by slot.
    @discardableResult
    func addAgentRow(slot: String, type: String, prefix: String = "", fixedNaming: Bool = false,
                     for projectId: UUID) -> Bool {
        addConfigRow(kind: .claude, slot: slot, type: type, prefix: prefix,
                     fixedNaming: fixedNaming, for: projectId)
    }

    /// Adds a declared terminal row (a label). Refuses an empty or duplicate slot.
    @discardableResult
    func addTerminalRow(slot: String, for projectId: UUID) -> Bool {
        addConfigRow(kind: .terminal, slot: slot, type: ConfigReconcile.defaultAgentType,
                     prefix: "", fixedNaming: false, for: projectId)
    }

    private func addConfigRow(kind: TerminalKind, slot: String, type: String, prefix: String,
                              fixedNaming: Bool, for projectId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        let trimmed = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !projects[index].terminals.contains(where: { $0.kind == kind && $0.slot == trimmed }) else {
            return false
        }
        // `claude` carries no line of its own, the way a hand written file means it.
        let command = kind == .claude && type != ConfigReconcile.defaultAgentType ? type : nil
        projects[index].terminals.append(
            TerminalRef(label: trimmed, sessionId: "", kind: kind, slot: trimmed, command: command,
                        fixedNaming: fixedNaming, prefix: prefix)
        )
        commitConfigEdits(for: projectId)
        return true
    }

    /// Edits a declared row. The slot must stay unique for its kind. For an agent
    /// row, `type` is the line it runs; it is applied only while the row is idle,
    /// because a running session keeps the line it was started with (the same rule
    /// `ConfigReconcile.apply` follows). `prefix` and `fixedNaming` are display and
    /// apply even to a running agent row; both are ignored for a terminal row.
    /// Refuses an empty or colliding slot, returning false so the row stays editing.
    @discardableResult
    func updateConfigRow(_ refId: UUID, slot: String, type: String, prefix: String,
                         fixedNaming: Bool, for projectId: UUID) -> Bool {
        guard let pIndex = projects.firstIndex(where: { $0.id == projectId }),
              let tIndex = projects[pIndex].terminals.firstIndex(where: { $0.id == refId }) else { return false }
        let kind = projects[pIndex].terminals[tIndex].kind
        let trimmed = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let collides = projects[pIndex].terminals.contains {
            $0.id != refId && $0.kind == kind && $0.slot == trimmed
        }
        guard !collides else { return false }
        projects[pIndex].terminals[tIndex].slot = trimmed
        projects[pIndex].terminals[tIndex].label = trimmed
        if kind == .claude {
            let hasSession = !projects[pIndex].terminals[tIndex].sessionId.isEmpty
            if !hasSession {
                projects[pIndex].terminals[tIndex].command =
                    type == ConfigReconcile.defaultAgentType ? nil : type
            }
            projects[pIndex].terminals[tIndex].prefix = prefix
            projects[pIndex].terminals[tIndex].fixedNaming = fixedNaming
        }
        commitConfigEdits(for: projectId)
        return true
    }

    /// Reorders the rows of one kind. The file writes agents then terminals in row
    /// order, so order within a kind is what the page can change; `offsets` and
    /// `destination` index into that kind's rows as the page lists them.
    func moveConfigRows(kind: TerminalKind, fromOffsets offsets: IndexSet, toOffset destination: Int,
                        for projectId: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }
        var ofKind = projects[index].terminals.filter { $0.kind == kind }
        let others = projects[index].terminals.filter { $0.kind != kind }
        ofKind.move(fromOffsets: offsets, toOffset: destination)
        // Keep the two kinds contiguous the way the file writes them: agents first,
        // then terminals, so the rebuilt config reads in the order the page shows.
        projects[index].terminals = kind == .claude ? ofKind + others : others + ofKind
        commitConfigEdits(for: projectId)
    }

    /// The user agreed to what the pending file wants to run, so it is applied now.
    func approvePendingConfig() {
        guard let request = pendingConfigApproval else { return }
        pendingConfigApproval = nil
        approve(request.commands, for: request.projectId)
        if reconcileWithFile(request.projectId) {
            configChangedOnDisk.remove(request.projectId)
        }
    }

    /// The user did not. Nothing is applied and nothing is recorded, so the question
    /// is asked again the next time the file is reached for, rather than the folder
    /// becoming one this app quietly ignores.
    func declinePendingConfig() {
        pendingConfigApproval = nil
    }

    private func load(cfg: [String: String], migrating: Bool) {
        projects = migrating ? Self.migrateWorkspaces(from: defaults, key: storageKey)
                             : Self.workspaces(from: cfg)
        for project in projects {
            if ConfigFile.exists(in: project.url) {
                reconcileWithFile(project.id)
                startWatching(project)
            }
            startGitWatching(project)
        }
    }

    /// Workspaces as this build wrote them: plain folder paths, no security-scoped
    /// bookmark.
    private static func workspaces(from cfg: [String: String]) -> [Project] {
        var loaded: [Project] = []
        var index = 0
        while let path = cfg["\(SettingsKeys.workspacePrefix)\(index).path"] {
            let base = "\(SettingsKeys.workspacePrefix)\(index)"
            var terminals: [TerminalRef] = []
            var t = 0
            while let label = cfg["\(base).terminal.\(t).label"] {
                let tk = "\(base).terminal.\(t)"
                terminals.append(TerminalRef(
                    id: cfg["\(tk).id"].flatMap { UUID(uuidString: $0) } ?? UUID(),
                    label: label,
                    sessionId: cfg["\(tk).session-id"] ?? "",
                    kind: TerminalKind(rawValue: cfg["\(tk).kind"] ?? "") ?? .terminal,
                    slot: cfg["\(tk).slot"] ?? label,
                    command: cfg["\(tk).command"],
                    fixedNaming: cfg["\(tk).fixed-naming"] == "true",
                    prefix: cfg["\(tk).prefix"] ?? ""
                ))
                t += 1
            }
            loaded.append(Project(
                id: cfg["\(base).id"].flatMap { UUID(uuidString: $0) } ?? UUID(),
                url: URL(fileURLWithPath: path).standardizedFileURL,
                terminals: terminals,
                displayName: cfg["\(base).name"],
                windowId: cfg["\(base).window-id"],
                groupId: cfg["\(base).group-id"].flatMap { UUID(uuidString: $0) },
                terminalSeq: cfg["\(base).terminal-seq"].flatMap(Int.init) ?? 0,
                claudeSeq: cfg["\(base).claude-seq"].flatMap(Int.init) ?? 0,
                collapsed: cfg["\(base).collapsed"] == "true"
            ))
            index += 1
        }
        return loaded
    }

    /// The old `[Data]` of security-scoped bookmarks, resolved to paths once so the
    /// next write is plain text. A bookmark that no longer resolves is dropped, the
    /// same as the previous loader did.
    private static func migrateWorkspaces(from defaults: UserDefaults, key: String) -> [Project] {
        guard let dataArray = defaults.array(forKey: key) as? [Data] else { return [] }
        let decoder = JSONDecoder()
        return dataArray.compactMap { data -> Project? in
            guard let record = try? decoder.decode(StoredProject.self, from: data) else { return nil }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: [],
                                     relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
            return Project(
                id: record.id, url: url.standardizedFileURL, terminals: record.terminals,
                displayName: record.displayName, windowId: record.windowId,
                terminalSeq: record.terminalSeq, claudeSeq: record.claudeSeq,
                collapsed: record.collapsed
            )
        }
    }

    /// The single write for every user-facing setting: scalars, agents, approvals, and
    /// workspaces, all rebuilt from the store's current state. Called from each
    /// setting's `didSet` and from `save()`, so the file always mirrors what the app
    /// holds. The secret is not here.
    ///
    /// Reported on failure rather than dropped: silence would leave the file and the
    /// screen disagreeing, with the change the user just made gone at the next launch.
    /// Returns whether the write happened, which the first-launch migration uses to
    /// decide whether it is safe to drop the old `UserDefaults` keys.
    @discardableResult
    private func persistSettings() -> Bool {
        // A launch that could not read the file does not write one either, so a
        // corrupt or half-written file is not overwritten with defaults.
        guard settingsPersistable else { return false }
        var pairs: [(key: String, value: String)] = [
            (SettingsKeys.showWorkspaceBadge, showWorkspaceBadge ? "true" : "false"),
            (SettingsKeys.bellSound, bellSound.stored),
            (SettingsKeys.checkIntervalFast, String(checkIntervals.fast)),
            (SettingsKeys.checkIntervalNormal, String(checkIntervals.normal)),
            (SettingsKeys.checkIntervalSlow, String(checkIntervals.slow)),
            (SettingsKeys.sidebarWidth, String(sidebarWidth)),
            (SettingsKeys.remoteEnabled, remoteEnabled ? "true" : "false"),
            (SettingsKeys.remotePort, String(remotePort)),
            (SettingsKeys.mcpPort, String(mcpPort)),
        ]
        pairs.append(contentsOf: sidebarColors.pairs)
        for (i, agent) in agents.enumerated() {
            pairs.append(("\(SettingsKeys.agentPrefix)\(i).name", agent.name))
            pairs.append(("\(SettingsKeys.agentPrefix)\(i).command", agent.command))
            pairs.append(("\(SettingsKeys.agentPrefix)\(i).args", agent.defaultArguments))
        }
        for (i, group) in groups.enumerated() {
            pairs.append(("\(SettingsKeys.groupPrefix)\(i).id", group.id.uuidString))
            pairs.append(("\(SettingsKeys.groupPrefix)\(i).name", group.name))
        }
        if let selectedGroupId {
            pairs.append((SettingsKeys.selectedGroup, selectedGroupId.uuidString))
        }
        // Sorted so the file is stable: an unordered set would reshuffle the lines on
        // every write and read as a change to anyone diffing the file.
        for (id, commands) in approvedCommands.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for (i, command) in commands.sorted().enumerated() {
                pairs.append(("\(SettingsKeys.approvedPrefix)\(id.uuidString).\(i)", command))
            }
        }
        for (i, project) in projects.enumerated() {
            pairs.append(contentsOf: Self.workspacePairs(project, index: i))
        }
        do {
            try configFile.write(pairs, managedKeys: SettingsKeys.scalars,
                                 managedPrefixes: SettingsKeys.prefixes)
            return true
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
            return false
        }
    }

    private static func workspacePairs(_ project: Project, index: Int) -> [(key: String, value: String)] {
        let base = "\(SettingsKeys.workspacePrefix)\(index)"
        var pairs: [(key: String, value: String)] = [
            ("\(base).path", project.url.standardizedFileURL.path),
            ("\(base).id", project.id.uuidString),
            ("\(base).collapsed", project.collapsed ? "true" : "false"),
            ("\(base).terminal-seq", String(project.terminalSeq)),
            ("\(base).claude-seq", String(project.claudeSeq)),
        ]
        if let name = project.displayName { pairs.append(("\(base).name", name)) }
        if let windowId = project.windowId { pairs.append(("\(base).window-id", windowId)) }
        if let groupId = project.groupId { pairs.append(("\(base).group-id", groupId.uuidString)) }
        for (t, ref) in project.terminals.enumerated() {
            let tk = "\(base).terminal.\(t)"
            pairs.append(("\(tk).id", ref.id.uuidString))
            pairs.append(("\(tk).label", ref.label))
            pairs.append(("\(tk).kind", ref.kind.rawValue))
            pairs.append(("\(tk).slot", ref.slot))
            // The app mostly mints ghostty-prefixed ids that `clearDeadSessions` wipes
            // on the next launch, so this is usually empty by the time it is read back.
            // It is still persisted: the clearing reads it to know what to clear, and a
            // non-prefixed id from another substrate is meant to survive.
            if !ref.sessionId.isEmpty { pairs.append(("\(tk).session-id", ref.sessionId)) }
            if let command = ref.command { pairs.append(("\(tk).command", command)) }
            // Written only when set, the way `command` is, so a plain row stays two
            // lines rather than sprouting `fixed-naming = false` and an empty prefix.
            if ref.fixedNaming { pairs.append(("\(tk).fixed-naming", "true")) }
            if !ref.prefix.isEmpty { pairs.append(("\(tk).prefix", ref.prefix)) }
        }
        return pairs
    }

    private func save() { persistSettings() }
}
