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
    /// The active group's id, or absent for "All". Resolved against the group list on
    /// load: an id no group answers to reads as "All" rather than hiding everything.
    static let selectedGroup = "selected-group"

    // The sidebar's own colours (`SidebarColors`), each a `#RRGGBB` value. Absent
    // means "leave the default"; the terminal's colours live in `ghostty.cfg`, not
    // here, because only libghostty can apply them.
    static let colorBackground = "color-background"
    static let colorForeground = "color-foreground"
    static let colorActiveWorkspaceBackground = "color-active-workspace-background"
    static let colorActiveWorkspaceForeground = "color-active-workspace-foreground"
    static let colorActiveTerminalRowBackground = "color-active-terminal-row-background"
    static let colorActiveTerminalRowForeground = "color-active-terminal-row-foreground"
    static let colorPillBackground = "color-pill-background"
    static let colorPillForeground = "color-pill-foreground"

    static let agentPrefix = "agent."
    static let workspacePrefix = "workspace."
    static let approvedPrefix = "approved."
    static let groupPrefix = "group."

    /// The single-key settings, for `WiettyConfigFile.write`: a scalar the store no
    /// longer carries (back at its default) is removed rather than left behind.
    static let scalars: Set<String> = [
        showWorkspaceBadge, bellSound, checkIntervalFast, checkIntervalNormal,
        checkIntervalSlow, sidebarWidth, remoteEnabled, remotePort, mcpPort,
        selectedGroup,
        colorBackground, colorForeground,
        colorActiveWorkspaceBackground, colorActiveWorkspaceForeground,
        colorActiveTerminalRowBackground, colorActiveTerminalRowForeground,
        colorPillBackground, colorPillForeground,
    ]

    /// The list prefixes, so a list that shrank loses its trailing entries.
    static let prefixes: [String] = [agentPrefix, workspacePrefix, approvedPrefix, groupPrefix]
}
