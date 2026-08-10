import Foundation

/// Pure mapping between terminal rows and the file config. No I/O, no app state.
enum ConfigReconcile {
    struct ApplyResult: Equatable {
        var terminals: [TerminalRef]
        var localOnly: Set<UUID>
    }

    /// Builds a config that mirrors the given rows. Claude rows become agents
    /// (keyed by slot), terminal rows become iterm labels, both in row order.
    static func config(
        from terminals: [TerminalRef], name: String?, processes: [String: ProcessConfig]? = nil,
        tests: [String: TestConfig]? = nil, shellInit: [String]? = nil
    ) -> WorkspaceConfig {
        let agents = terminals
            .filter { $0.kind == .claude }
            .map { WorkspaceConfig.Agent(slot: $0.slot, type: "claude") }
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

        func take(kind: TerminalKind, slot: String) -> TerminalRef {
            if let index = remaining.firstIndex(where: { $0.kind == kind && $0.slot == slot }) {
                return remaining.remove(at: index)
            }
            return TerminalRef(label: slot, sessionId: "", kind: kind, slot: slot)
        }

        for agent in config.agents {
            result.append(take(kind: .claude, slot: agent.slot))
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
