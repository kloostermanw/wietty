import Foundation

/// The keys the store reads and writes in `~/.config/wietty/config`.
///
/// One place for the spelling of every line the file carries, so the reader, the
/// writer, and `docs/settings-storage.md` cannot drift apart. Scalars are single
/// keys; lists are indexed prefixes (`agent.0.name`, `workspace.1.path`,
/// `approved.<uuid>.0`), which is also how a shrunk list drops its stale entries: see
/// `WiettyConfigFile.write(_:managedKeys:managedPrefixes:)`.
enum SettingsKeys {
    static let showWorkspaceBadge = "show-workspace-badge"
    static let bellSound = "bell-sound"
    static let checkIntervalFast = "check-interval-fast"
    static let checkIntervalNormal = "check-interval-normal"
    static let checkIntervalSlow = "check-interval-slow"
    static let sidebarWidth = "sidebar-width"
    static let remoteEnabled = "remote-enabled"
    static let remotePort = "remote-port"
    static let mcpPort = "mcp-port"

    static let agentPrefix = "agent."
    static let workspacePrefix = "workspace."
    static let approvedPrefix = "approved."

    /// The single-key settings, for `WiettyConfigFile.write`: a scalar the store no
    /// longer carries (back at its default) is removed rather than left behind.
    static let scalars: Set<String> = [
        showWorkspaceBadge, bellSound, checkIntervalFast, checkIntervalNormal,
        checkIntervalSlow, sidebarWidth, remoteEnabled, remotePort, mcpPort,
    ]

    /// The list prefixes, so a list that shrank loses its trailing entries.
    static let prefixes: [String] = [agentPrefix, workspacePrefix, approvedPrefix]
}
