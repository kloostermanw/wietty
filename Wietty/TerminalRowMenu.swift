import Foundation

/// One entry in a terminal or agent row's context menu.
///
/// Values rather than closures, so the menu's shape can be asserted without a row and
/// without a click, the same way `WorkspaceMenu` models the card's menu.
/// `WorkspaceCardView` maps each one onto the action it stands for, which is the part
/// that needs the row.
enum TerminalRowMenuItem: Equatable, Identifiable {
    /// Relabels the row. Offered only for a terminal: an agent row runs `claude`, not
    /// an interactive shell whose label a user picks.
    case rename
    /// Copies the row's `sessionId` to the pasteboard so another agent can be pointed
    /// at this session through the MCP tools.
    case copyId
    case remove
    case close

    var id: String { String(describing: self) }

    var title: String {
        switch self {
        case .rename: return "Rename"
        case .copyId: return "Copy ID for agent"
        case .remove: return "Remove"
        case .close: return "Close terminal"
        }
    }
}

/// The menu itself: which items a row offers and in what order.
enum TerminalRowMenu {
    /// - Parameter kind: a terminal row can be renamed; an agent row cannot, so "Rename"
    ///   is present only for `.terminal`. Every other item is offered for both.
    static func items(kind: TerminalKind) -> [TerminalRowMenuItem] {
        var items: [TerminalRowMenuItem] = []
        if kind == .terminal { items.append(.rename) }
        items.append(contentsOf: [.copyId, .remove, .close])
        return items
    }
}
