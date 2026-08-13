import Foundation

/// Pure mapping between terminal rows and the file config. No I/O, no app state.
enum ConfigReconcile {
    struct ApplyResult: Equatable {
        var terminals: [TerminalRef]
        var localOnly: Set<UUID>
    }

    /// What an agent row with no line of its own runs, and therefore the `type` it
    /// is written down as. Every file written before agents were configurable says
    /// this, and so does every hand written one.
    static let defaultAgentType = "claude"

    /// Builds a config that mirrors the given rows. Agent rows become agents
    /// (keyed by slot), terminal rows become iterm labels, both in row order.
    ///
    /// An agent's `type` is the line it runs, so a workspace whose file is synced can
    /// write down a row for something other than Claude. Writing `claude` for every
    /// agent row rewrote a Codex row as a Claude row on the next apply.
    static func config(
        from terminals: [TerminalRef], name: String?, processes: [String: ProcessConfig]? = nil,
        tests: [String: TestConfig]? = nil, shellInit: [String]? = nil
    ) -> WorkspaceConfig {
        let agents = terminals
            .filter { $0.kind == .claude }
            .map { WorkspaceConfig.Agent(slot: $0.slot, type: $0.command ?? defaultAgentType) }
        let iterm = terminals
            .filter { $0.kind == .terminal }
            .map(\.slot)
        return WorkspaceConfig(
            name: name, agents: agents, terminals: iterm, processes: processes, tests: tests,
            shellInit: shellInit
        )
    }

    /// Reconciles existing rows against a desired config. Matching rows (by kind
    /// and slot) are reused so their id, session, and live label survive. Missing
    /// desired entries become empty rows. Existing rows with no desired entry are
    /// dropped unless they have a session, in which case they are kept and marked
    /// local-only. Result order: desired agents, desired iterm, then local-only.
    static func apply(
        _ config: WorkspaceConfig,
        to existing: [TerminalRef],
        hasSession: (TerminalRef) -> Bool = { !$0.sessionId.isEmpty }
    ) -> ApplyResult {
        var remaining = existing
        var result: [TerminalRef] = []

        func take(kind: TerminalKind, slot: String, command: String? = nil) -> TerminalRef {
            if let index = remaining.firstIndex(where: { $0.kind == kind && $0.slot == slot }) {
                var existing = remaining.remove(at: index)
                // The file decides what the row runs, the same way it decides which
                // rows there are: an agent's `type` edited on disk has to reach the
                // row it names rather than being kept out by what that row ran before.
                existing.command = command
                return existing
            }
            return TerminalRef(label: slot, sessionId: "", kind: kind, slot: slot, command: command)
        }

        for agent in config.agents {
            // `claude` maps back to no line of its own, which is what it meant before
            // rows carried one and what a hand written file means by it.
            let command = agent.type == defaultAgentType ? nil : agent.type
            result.append(take(kind: .claude, slot: agent.slot, command: command))
        }
        for label in config.terminals {
            result.append(take(kind: .terminal, slot: label))
        }

        var localOnly: Set<UUID> = []
        for leftover in remaining where hasSession(leftover) {
            localOnly.insert(leftover.id)
            result.append(leftover)
        }
        return ApplyResult(terminals: result, localOnly: localOnly)
    }
}
