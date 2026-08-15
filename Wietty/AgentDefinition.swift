import Foundation

/// One agent the workspace menu can start: what it is called, what it runs, and
/// the arguments it runs with unless someone types others.
///
/// A pure type carrying the composition rule, rather than the menu or the store
/// joining a command and its arguments themselves. Two callers need that line ("Add
/// Agent", with the defaults, and "Add Agent with args", with what was typed), and
/// two copies of a string join is two places for a missing space.
///
/// The command is a line typed into an interactive shell, not an argv. That is what
/// the shell a row runs in expects (`ProjectStore.openShell`), and it is why the
/// arguments are one free text field rather than a list: whatever the user would
/// type at a prompt is what gets typed.
struct AgentDefinition: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var command: String
    var defaultArguments: String

    init(id: UUID = UUID(), name: String, command: String, defaultArguments: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.defaultArguments = defaultArguments
    }

    /// Tolerant on purpose, the way `TerminalRef`'s is: this is stored data, and it
    /// outlives the shape it was written in. A synthesized decoder makes every field
    /// required, so one field added in a later release would make every entry
    /// unreadable, and the list a user built disappears on upgrade.
    ///
    /// An entry missing a name or a command is still readable, and `isValid` is what
    /// keeps it out of the menu.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        defaultArguments = try c.decodeIfPresent(String.self, forKey: .defaultArguments) ?? ""
    }

    /// The app's own hardcoded agent, written down. A fresh install has to offer
    /// what the workspace menu offered before this list existed.
    static let claude = AgentDefinition(name: "Claude", command: "claude")

    /// The line to type into the shell.
    ///
    /// - Parameter arguments: what "Add Agent with args" collected, or nil for a
    ///   plain "Add Agent", which uses the defaults. An empty string is not nil: the
    ///   field is pre-filled with the defaults, so clearing it is how a user asks for
    ///   the bare command, and falling back to the defaults there would ignore them
    ///   doing so.
    func launchCommand(arguments: String? = nil) -> String {
        let chosen = (arguments ?? defaultArguments).trimmed
        let base = command.trimmed
        return chosen.isEmpty ? base : "\(base) \(chosen)"
    }

    /// A menu item needs a name and a shell line needs a command, so an entry
    /// missing either cannot be saved.
    var isValid: Bool { !name.trimmed.isEmpty && !command.trimmed.isEmpty }

    /// The name as the menu and a row's label show it. Trimmed for the same reason
    /// the command is: it is typed into a text field.
    var displayName: String { name.trimmed }
}

/// One stored entry, or nothing when it cannot be read.
///
/// Wraps the element so a list decodes entry by entry: one unreadable entry costs
/// that entry rather than every agent the user configured.
struct FailableAgentDefinition: Decodable {
    let agent: AgentDefinition?

    init(from decoder: any Decoder) throws {
        agent = try? AgentDefinition(from: decoder)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
