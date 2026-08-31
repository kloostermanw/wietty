import Foundation

/// Whether the commands in a workspace's `wietty.json` have been agreed to.
///
/// A `wietty.json` is not a layout description. Every part of it that matters here
/// is a shell line this app will run in the workspace's folder: an agent's `type`
/// is typed into that row's shell, a process or test `command` is run by the
/// supervisor, and `shell_init` runs before each of those. A process with
/// `auto_start` needs no click at all, so adding a folder was enough to run
/// whatever its file said.
///
/// That is fine for a file the user wrote and not fine for one that arrived with a
/// clone, and nothing in the file distinguishes them. So the user does, once, and
/// this type decides when that question has to be asked.
///
/// Pure: it holds no state and reads nothing. `ProjectStore` keeps the answers.
enum ConfigTrust {
    /// What running this config would put through a shell, in the order the file
    /// reads.
    ///
    /// The default agent type is left out on purpose. It is what this app has always
    /// run for an agent row, from before the file could name a line at all, so
    /// listing it would ask every existing workspace to approve the app's own
    /// behaviour. Everything a file can actually choose is included.
    static func commands(in config: WorkspaceConfig) -> [String] {
        var found: [String] = []
        for agent in config.agents where agent.type != ConfigReconcile.defaultAgentType {
            found.append(agent.type)
        }
        found.append(contentsOf: config.shellInit ?? [])
        // Sorted by name so the list a user is shown does not reorder itself between
        // two reads of the same file: `processes` and `tests` are dictionaries.
        for (_, process) in (config.processes ?? [:]).sorted(by: { $0.key < $1.key }) {
            found.append(process.command)
            if let stop = process.stop { found.append(stop) }
            if let status = process.status { found.append(status) }
            found.append(contentsOf: process.shellInit)
        }
        for (_, test) in (config.tests ?? [:]).sorted(by: { $0.key < $1.key }) {
            found.append(test.command)
            found.append(contentsOf: test.shellInit)
        }
        // A check's command runs shell in the workspace on the poll tick, so it is
        // agreed to the same way a test's command is, not left to run unapproved.
        for (_, check) in (config.checks ?? [:]).sorted(by: { $0.key < $1.key }) {
            found.append(check.command)
        }
        return found.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whether this config can be applied, and what has never been agreed to if not.
    ///
    /// Membership rather than a fingerprint of the whole file, so that removing a
    /// command, renaming a workspace or reordering rows does not ask again. Only a
    /// line nobody has seen does, which is the only change that can run something
    /// new.
    static func approval(for config: WorkspaceConfig,
                         approved: Set<String>) -> Approval {
        var unapproved: [String] = []
        for command in commands(in: config) where !approved.contains(command) {
            // Deduplicated: the same line in two processes is one thing to agree to,
            // and a list that repeats it reads as two.
            if !unapproved.contains(command) { unapproved.append(command) }
        }
        return unapproved.isEmpty ? .allowed : .needed(unapproved)
    }

    enum Approval: Equatable {
        /// Nothing here that has not been agreed to before.
        case allowed
        /// These lines have not, so nothing in the file runs until they are.
        case needed([String])
    }
}
