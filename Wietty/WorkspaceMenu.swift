import Foundation

/// One entry in a workspace card's context menu.
///
/// Values rather than closures, so the menu's shape can be asserted without a card
/// and without a click. `WorkspaceCardView` maps each one onto the action it stands
/// for, which is the part that needs the card.
enum WorkspaceMenuItem: Equatable, Identifiable {
    case addTerminal
    /// A submenu over the configured agents, each starting one with its default
    /// arguments.
    case addAgent
    /// The same list, each entry first asking what to run the agent with.
    case addAgentWithArgs
    /// The other Mac's Claude, on a remote card. The agent list is this Mac's
    /// preference and cannot be sent over the protocol, which offers a terminal and
    /// Claude and nothing else.
    case addClaude
    case addWorkspace
    case separator
    case editWorkspace
    case renameWorkspace
    case enableConfigSync
    case removeWorkspace

    var id: String { String(describing: self) }

    /// The item's label, and empty for the separator, which has none.
    var title: String {
        switch self {
        case .addTerminal: return "Add Terminal"
        case .addAgent: return "Add Agent"
        case .addAgentWithArgs: return "Add Agent with args"
        case .addClaude: return "Claude"
        case .addWorkspace: return "Add workspace…"
        case .separator: return ""
        case .editWorkspace: return "Edit workspace…"
        case .renameWorkspace: return "Rename workspace…"
        case .enableConfigSync: return "Enable config sync"
        case .removeWorkspace: return "Remove"
        }
    }

    /// Whether this item is a submenu built from the agent list, so an agent added
    /// in Settings appears under both without either being rebuilt.
    var isAgentSubmenu: Bool { self == .addAgent || self == .addAgentWithArgs }
}

/// The menu itself: which items a card offers and in what order.
enum WorkspaceMenu {
    /// What an empty agent submenu says, disabled. A submenu with nothing at all in
    /// it reads as a menu that failed to build, so it points at where agents are
    /// configured instead.
    static let noAgents = "No agents yet. Add one in Settings › Agents."

    /// - Parameters:
    ///   - isLocal: false for a card belonging to another Mac. Those workspaces are
    ///     not this app's to edit, rename or remove, and the two "add" entries it
    ///     does offer are the two the remote protocol carries.
    ///   - syncEnabled: whether this workspace already writes a `wietty.json`. Sync
    ///     can only be turned on, so the item is absent once it is.
    static func items(isLocal: Bool, syncEnabled: Bool) -> [WorkspaceMenuItem] {
        guard isLocal else { return [.addTerminal, .addClaude] }
        // Everything that adds something first, then a separator, then everything
        // that acts on the workspace itself: "Remove" sitting among the four "add"
        // entries is how a click meant for one lands on the other.
        var items: [WorkspaceMenuItem] = [
            .addTerminal, .addAgent, .addAgentWithArgs, .addWorkspace,
            .separator, .editWorkspace, .renameWorkspace
        ]
        if !syncEnabled { items.append(.enableConfigSync) }
        items.append(.removeWorkspace)
        return items
    }
}
