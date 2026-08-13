import Foundation

enum TerminalKind: String, Codable {
    case terminal
    case claude
}

struct TerminalRef: Identifiable, Equatable, Codable {
    let id: UUID
    var label: String
    var sessionId: String
    var kind: TerminalKind
    var slot: String
    /// The line this row types into its shell, or nil for a row that runs whatever
    /// its kind runs (`ProjectStore.command(for:)`: nothing for a terminal, `claude`
    /// for an agent row).
    ///
    /// Stored on the row rather than looked up in the agent list when it is needed,
    /// because it is needed three times after the row is opened: clicking a row
    /// whose terminal died, restarting one, and starting an agent that exited back
    /// to a prompt. The list can be edited or emptied between any two of those, and a
    /// row that changed what it runs because someone renamed an entry in Settings
    /// would be a surprise. Nil on every row stored before the list existed and on
    /// every row imported from a `wietty.json`, which is what keeps those running
    /// `claude`.
    var command: String?

    init(id: UUID = UUID(), label: String, sessionId: String, kind: TerminalKind = .terminal,
         slot: String? = nil, command: String? = nil) {
        self.id = id
        self.label = label
        self.sessionId = sessionId
        self.kind = kind
        self.slot = slot ?? label
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, sessionId, kind, slot, command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        kind = try container.decodeIfPresent(TerminalKind.self, forKey: .kind) ?? .terminal
        slot = try container.decodeIfPresent(String.self, forKey: .slot) ?? label
        command = try container.decodeIfPresent(String.self, forKey: .command)
    }
}
