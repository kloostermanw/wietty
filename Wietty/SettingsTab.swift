import Foundation

/// One group of settings, and therefore one segment in the control above the
/// settings form.
///
/// A pure type rather than a set of cases inlined into `SettingsView`, for the same
/// reason `NavBarView.trailingButtons` is a static function: which tabs the panel
/// offers and in what order is then asserted in CI rather than only checkable by
/// opening the panel.
///
/// `Agents` is here ahead of any setting to put in it. The app has the concept
/// already (`WorkspaceConfig.Agent`), it is not configurable yet, and giving it a
/// tab now means the settings that arrive later have a place to go instead of
/// another regrouping. `Notifications` was the same and is no longer: it was filled
/// in, which is what the reserved space was for.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case notifications
    case agents
    case remote
    case mcp

    var id: String { rawValue }

    /// The segment's label. Not derived from `rawValue`: "MCP" is an initialism
    /// that no capitalisation rule produces from `mcp`.
    var title: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .agents: return "Agents"
        case .remote: return "Remote"
        case .mcp: return "MCP"
        }
    }

    /// Which tab the panel opens on. Named rather than taken from `allCases.first`,
    /// even though it currently is the first: reordering the segments is a layout
    /// decision, and it should not silently move where the panel lands.
    static let `default`: SettingsTab = .general

    /// What a tab with no settings yet draws instead of a form, or nil when it has
    /// settings of its own.
    ///
    /// The copy lives here rather than in the view's `switch` so that a tab and the
    /// reason it is empty stay one thing: adding the first real setting to `Agents`
    /// means deleting its case here, and the view follows. That is exactly what
    /// filling the Notifications tab did.
    var placeholder: Placeholder? {
        switch self {
        case .agents:
            return Placeholder(
                title: "No agent settings yet",
                message: "Settings for the agents a workspace starts will appear here.",
                systemImage: "sparkles")
        case .mcp, .remote, .general, .notifications:
            return nil
        }
    }

    /// Whether this tab has no settings yet, which is the same question as whether
    /// it has a placeholder.
    var isEmptyForNow: Bool { placeholder != nil }

    /// The empty state of a tab that exists ahead of its settings.
    struct Placeholder: Equatable {
        let title: String
        let message: String
        let systemImage: String
    }
}
