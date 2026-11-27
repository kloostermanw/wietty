import Foundation

/// The keys the store reads and writes in `~/.config/wietty/config`.
///
/// One place for the spelling of every line the file carries, so the reader, the
/// writer, and `docs/settings-storage.md` cannot drift apart. Scalars are single
/// keys; lists are indexed prefixes (`agent.0.name`, `workspace.1.path`,
/// `approved.<uuid>.0`), which is also how a shrunk list drops its stale entries: see
/// `WiettyConfigFile.write(_:managedKeys:managedPrefixes:)`.
package enum SettingsKeys {
    package static let bellSound = "bell-sound"
    package static let notificationSource = "notification-source"
    package static let checkIntervalFast = "check-interval-fast"
    package static let checkIntervalNormal = "check-interval-normal"
    package static let checkIntervalSlow = "check-interval-slow"
    package static let sidebarWidth = "sidebar-width"
    package static let remoteEnabled = "remote-enabled"
    package static let remotePort = "remote-port"
    package static let mcpPort = "mcp-port"
    /// Lines of history each terminal's screen model keeps, `TerminalScrollback`.
    package static let scrollbackLines = "scrollback-lines"
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
        bellSound, notificationSource, checkIntervalFast, checkIntervalNormal,
        checkIntervalSlow, sidebarWidth, remoteEnabled, remotePort, mcpPort,
        scrollbackLines, selectedGroup,
        colorBackground, colorForeground,
        colorActiveWorkspaceBackground, colorActiveWorkspaceForeground,
        colorActiveTerminalRowBackground, colorActiveTerminalRowForeground,
        colorPillBackground, colorPillForeground,
    ]

    /// Keys Wietty once wrote and no longer reads. A file from an older build may
    /// still hold one. It is read past like any key nothing asks for, and the next
    /// write removes its line, as it removes the line of a setting back at its
    /// default: a retired key is one Wietty knows, not one of the user's own, which
    /// are kept. Not in `scalars`, so no source owns one and nothing preserves it.
    ///
    /// `show-workspace-badge` named terminals after their workspace when the
    /// terminals were another application's windows. libghostty has no way to set a
    /// surface's title, so the setting did nothing, and it was removed.
    package static let retired: Set<String> = ["show-workspace-badge"]

    /// The order the managed lines appear in the file, as exact keys and as list
    /// prefixes.
    ///
    /// The layout used to be implicit in the order one method appended its pairs.
    /// Once two objects contribute lines, that would make the file's shape depend on
    /// which of them was registered first, and the four settings that moved to
    /// `UIPreferences` are interleaved with the store's rather than grouped at
    /// either end. Stating the order here keeps the file byte identical to what the
    /// single writer produced, and keeps it that way whatever is added next.
    ///
    /// A key that matches nothing here is written after everything that does, in the
    /// order its source gave it.
    package static let fileOrder: [String] = [
        bellSound, notificationSource,
        checkIntervalFast, checkIntervalNormal, checkIntervalSlow,
        sidebarWidth, remoteEnabled, remotePort, mcpPort,
        // After the two ports: with them it is the block the server side reads, and
        // behind them so a file written before it existed gains one line below
        // lines it already had rather than having them move.
        scrollbackLines,
        colorBackground, colorForeground,
        colorActiveWorkspaceBackground, colorActiveWorkspaceForeground,
        colorActiveTerminalRowBackground, colorActiveTerminalRowForeground,
        colorPillBackground, colorPillForeground,
        agentPrefix, groupPrefix, selectedGroup, approvedPrefix, workspacePrefix,
    ]

    /// The list prefixes, so a list that shrank loses its trailing entries.
    package static let prefixes: [String] = [agentPrefix, workspacePrefix, approvedPrefix, groupPrefix]
}

/// The scalar keys `UIPreferences` owns: the settings that are this Mac's view of
/// the data rather than part of it (issue #84).
///
/// Here rather than on `UIPreferences`, which is in the app, because the store needs
/// to name the complement of this set and cannot see across the boundary.
package enum UIPreferencesKeys {
    package static let all: Set<String> = [
        SettingsKeys.bellSound, SettingsKeys.sidebarWidth, SettingsKeys.selectedGroup,
        SettingsKeys.colorBackground, SettingsKeys.colorForeground,
        SettingsKeys.colorActiveWorkspaceBackground, SettingsKeys.colorActiveWorkspaceForeground,
        SettingsKeys.colorActiveTerminalRowBackground, SettingsKeys.colorActiveTerminalRowForeground,
        SettingsKeys.colorPillBackground, SettingsKeys.colorPillForeground,
    ]
}
