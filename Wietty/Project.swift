import Foundation

struct Project: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var terminals: [TerminalRef]
    /// The name typed in this app, or nil for a workspace that was never renamed.
    /// Persisted with the rest of the record, and deliberately local: renaming here
    /// must not write a file inside the user's git working tree, and it does not
    /// travel to another machine. Sharing a name is what `wietty.json` is for.
    var displayName: String?
    var windowId: String?
    /// The group this workspace is filed under (`WorkspaceGroup.id`), or nil for one
    /// that belongs to no group. Local like `displayName`: which group a workspace is
    /// in is this machine's organization of the sidebar, not something to write into
    /// the git tree, so it persists to `~/.config/wietty/config` and never travels in
    /// `wietty.json`.
    var groupId: UUID?
    var terminalSeq: Int
    var claudeSeq: Int
    var collapsed: Bool
    var configName: String?
    var configProcesses: [String: ProcessConfig]?
    var configTests: [String: TestConfig]?
    /// The file's workspace-wide `shell_init` lines. Held so a rewrite of the
    /// file preserves them; like `configName`, re-established from the file by
    /// `reconcileWithFile` rather than persisted.
    var configShellInit: [String]?

    /// Display name: the config file's `name` override when present, else the
    /// folder name. `configName` is re-established from the file by
    /// `reconcileWithFile` on every launch; it is not persisted directly.
    ///
    /// `displayName` wins over both. A rename typed in this app is the most
    /// specific thing anyone has said about what this workspace is called: more
    /// specific than a file that travelled in with the repository, and more than
    /// the folder it happens to live in. Without that precedence a rename would
    /// silently do nothing for exactly those workspaces that carry a `name` in
    /// their `wietty.json`.
    var name: String { displayName ?? configName ?? url.lastPathComponent }

    /// True when the folder is a git repository (has a `.git` directory or file).
    var isGitRepository: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    init(
        id: UUID = UUID(),
        url: URL,
        terminals: [TerminalRef] = [],
        displayName: String? = nil,
        windowId: String? = nil,
        groupId: UUID? = nil,
        terminalSeq: Int = 0,
        claudeSeq: Int = 0,
        collapsed: Bool = false,
        configName: String? = nil,
        configProcesses: [String: ProcessConfig]? = nil,
        configTests: [String: TestConfig]? = nil,
        configShellInit: [String]? = nil
    ) {
        self.id = id
        self.url = url
        self.terminals = terminals
        self.displayName = displayName
        self.windowId = windowId
        self.groupId = groupId
        self.terminalSeq = terminalSeq
        self.claudeSeq = claudeSeq
        self.collapsed = collapsed
        self.configName = configName
        self.configProcesses = configProcesses
        self.configTests = configTests
        self.configShellInit = configShellInit
    }
}
