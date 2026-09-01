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
    /// When true, an agent row keeps showing its `slot` and a reported title is
    /// ignored rather than replacing `label`. Set from the agent's `fixed_naming` in
    /// `wietty.json`; false for terminal rows and rows predating the field. Issue #37.
    var fixedNaming: Bool
    /// Prepended to the displayed name, with a single space, whatever the name is.
    /// Set from the agent's `prefix` in `wietty.json`; empty means no prefix.
    var prefix: String

    init(id: UUID = UUID(), label: String, sessionId: String, kind: TerminalKind = .terminal,
         slot: String? = nil, command: String? = nil, fixedNaming: Bool = false, prefix: String = "") {
        self.id = id
        self.label = label
        self.sessionId = sessionId
        self.kind = kind
        self.slot = slot ?? label
        self.command = command
        self.fixedNaming = fixedNaming
        self.prefix = prefix
    }

    /// The name a row shows: the `prefix` (when set) in front of the base name.
    ///
    /// The base is `slot` under `fixedNaming` and `label` otherwise. Deriving it here
    /// rather than only guarding the title event is what makes `fixed_naming` take
    /// effect at once even on a row whose `label` a reported title already changed:
    /// turning the flag on snaps the shown name back to the slot without waiting for
    /// the row to be reopened. When the flag is off, `label` already holds whichever
    /// name won (the slot, a reported title, or a manual rename).
    ///
    /// The prefix is trimmed so a stray trailing space in the config does not double
    /// up the separator, and a prefix that is only whitespace reads as none. Issue #37.
    var displayName: String { displayName(liveLabel: nil) }

    /// The name a row shows, given an optional live agent-reported title.
    ///
    /// The base is `slot` under `fixedNaming` (a pinned row ignores reported titles,
    /// live or stored), the `liveLabel` when one is supplied, otherwise the stored
    /// `label`. The prefix is applied to whichever base wins. A live title is a
    /// display-only override held outside the model (`ProjectStore.liveLabels`), so a
    /// busy agent retitling constantly no longer mutates the row and re-renders the
    /// sidebar. Issue #60.
    func displayName(liveLabel: String?) -> String {
        let base = fixedNaming ? slot : (liveLabel ?? label)
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? base : "\(p) \(base)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, sessionId, kind, slot, command, fixedNaming, prefix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        kind = try container.decodeIfPresent(TerminalKind.self, forKey: .kind) ?? .terminal
        slot = try container.decodeIfPresent(String.self, forKey: .slot) ?? label
        command = try container.decodeIfPresent(String.self, forKey: .command)
        fixedNaming = try container.decodeIfPresent(Bool.self, forKey: .fixedNaming) ?? false
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
    }
}
