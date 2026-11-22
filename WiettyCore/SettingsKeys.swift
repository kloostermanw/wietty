import Foundation

/// The keys the store reads and writes in `~/.config/wietty/config`.
///
/// One place for the spelling of every line the file carries, so the reader, the
/// writer, and `docs/settings-storage.md` cannot drift apart. Scalars are single
/// keys; lists are indexed prefixes (`agent.0.name`, `workspace.1.path`,
/// `approved.<uuid>.0`), which is also how a shrunk list drops its stale entries: see
/// `WiettyConfigFile.write(_:managedKeys:managedPrefixes:)`.
package enum SettingsKeys {
    package static let showWorkspaceBadge = "show-workspace-badge"
    package static let bellSound = "bell-sound"
    package static let notificationSource = "notification-source"
    package static let checkIntervalFast = "check-interval-fast"
    package static let checkIntervalNormal = "check-interval-normal"
    package static let checkIntervalSlow = "check-interval-slow"
    package static let sidebarWidth = "sidebar-width"
    package static let remoteEnabled = "remote-enabled"
    package static let remotePort = "remote-port"
    package static let mcpPort = "mcp-port"
    /// The active group's id, or absent for "All". Resolved against the group list on
    /// load: an id no group answers to reads as "All" rather than hiding everything.
    package static let selectedGroup = "selected-group"

    // The sidebar's own colours (`SidebarColors`), each a `#RRGGBB` value. Absent
    // means "leave the default"; the terminal's colours live in `ghostty.cfg`, not
    // here, because only libghostty can apply them.
    package static let colorBackground = "color-background"
    package static let colorForeground = "color-foreground"
    package static let colorActiveWorkspaceBackground = "color-active-workspace-background"
    package static let colorActiveWorkspaceForeground = "color-active-workspace-foreground"
    package static let colorActiveTerminalRowBackground = "color-active-terminal-row-background"
    package static let colorActiveTerminalRowForeground = "color-active-terminal-row-foreground"
    package static let colorPillBackground = "color-pill-background"
    package static let colorPillForeground = "color-pill-foreground"

    package static let agentPrefix = "agent."
    package static let workspacePrefix = "workspace."
    package static let approvedPrefix = "approved."
    package static let groupPrefix = "group."

    /// The single-key settings, for `WiettyConfigFile.write`: a scalar the store no
    /// longer carries (back at its default) is removed rather than left behind.
    package static let scalars: Set<String> = [
        showWorkspaceBadge, bellSound, notificationSource, checkIntervalFast, checkIntervalNormal,
        checkIntervalSlow, sidebarWidth, remoteEnabled, remotePort, mcpPort,
        selectedGroup,
        colorBackground, colorForeground,
        colorActiveWorkspaceBackground, colorActiveWorkspaceForeground,
        colorActiveTerminalRowBackground, colorActiveTerminalRowForeground,
        colorPillBackground, colorPillForeground,
    ]

    /// The list prefixes, so a list that shrank loses its trailing entries.
    package static let prefixes: [String] = [agentPrefix, workspacePrefix, approvedPrefix, groupPrefix]
}
