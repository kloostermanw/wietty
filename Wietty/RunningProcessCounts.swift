import Foundation

/// How much is running across every workspace, by kind: local terminals, agents, and
/// the managed processes and tests that workspaces declare in `wietty.json`. Shown by
/// `StatusBarView`.
struct RunningProcessCounts: Equatable, Sendable {
    var terminals: Int
    var agents: Int
    var processes: Int
    var tests: Int

    var total: Int { terminals + agents + processes + tests }

    /// The status bar's text.
    var summary: String { "\(total) running" }

    /// The status bar's tooltip, which tells the kinds apart.
    var detail: String {
        "\(Self.plural(terminals, "terminal", "terminals")), "
            + "\(Self.plural(agents, "agent", "agents")), "
            + "\(Self.plural(processes, "process", "processes")) and "
            + "\(Self.plural(tests, "test", "tests")) running"
    }

    private static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}

extension ProjectStore {
    /// Counted on read from state that is `@Observable` (the store's job names and
    /// both supervisors), so a view reading this redraws when anything starts or
    /// stops.
    ///
    /// Terminals and agents count by `isSessionRunning`, the rule that tints a row's
    /// glyph green in the sidebar: a terminal while its shell lives, an agent only
    /// while the agent is the foreground job, so one that quit back to its shell does
    /// not count. Processes and tests count by `processIsRunning`, the rule the rows
    /// use for their stop button: starting and stopping count, and so does an orphan
    /// that is still alive.
    var runningProcessCounts: RunningProcessCounts {
        var counts = RunningProcessCounts(terminals: 0, agents: 0, processes: 0, tests: 0)
        for project in projects {
            for ref in project.terminals where isSessionRunning(ref) {
                switch ref.kind {
                case .terminal: counts.terminals += 1
                case .claude: counts.agents += 1
                }
            }
            counts.processes += processes.processes(for: project.id).filter { processIsRunning(for: $0.state) }.count
            counts.tests += testSupervisor.tests(for: project.id).filter { processIsRunning(for: $0.state) }.count
        }
        return counts
    }
}
