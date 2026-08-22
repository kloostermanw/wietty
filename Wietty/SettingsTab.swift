import Foundation

/// One group of settings, and therefore one segment in the control above the
/// settings form.
///
/// A pure type rather than a set of cases inlined into `SettingsView`, for the same
/// reason `NavBarView.trailingButtons` is a static function: which tabs the panel
/// offers and in what order is then asserted in CI rather than only checkable by
/// opening the panel.
///
/// Every tab now holds settings of its own. Two of them (`Notifications`, then
/// `Agents`) were here ahead of any setting to put in, each drawing a placeholder
/// that said what it was waiting for, and each lost it when it was filled in. That
/// is what the reserved space was for, and why the placeholder machinery is gone
/// with the last of them.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case notifications
    case agents
    case promptTemplates
    case remote
    case mcp

    var id: String { rawValue }

    /// The segment's label. Not derived from `rawValue`: "MCP" is an initialism
    /// that no capitalisation rule produces from `mcp`. Kept terse ("Prompts", not
    /// "Prompt templates") because the six segments share the pane's floor width, and
    /// a long label there would push that floor, and the whole window's minimum, wider.
    /// The section header and the app menu spell it out in full.
    var title: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .agents: return "Agents"
        case .promptTemplates: return "Prompts"
        case .remote: return "Remote"
        case .mcp: return "MCP"
        }
    }

    /// Which tab the panel opens on. Named rather than taken from `allCases.first`,
    /// even though it currently is the first: reordering the segments is a layout
    /// decision, and it should not silently move where the panel lands.
    static let `default`: SettingsTab = .general
}
