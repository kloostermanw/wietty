import Foundation
import Observation

/// Owns the on-demand run of each workspace's freshness `checks` and reconciles
/// them against the on-disk `checks` definitions. A check is run-to-completion, so
/// it is a `ManagedProcess` in `short_running` mode, the same shape a test is; this
/// is the run-now-and-open-log half of a check, reached from the card's "Checks"
/// submenu.
///
/// The scheduled `!` marker is a separate path (`ProjectStore` drives
/// `FreshnessService` on a tick), so this type carries none of that path's
/// watch-file caching or staleness tracking: a check here runs when the user asks
/// and its output is what "Open log" shows. Both paths run the same command with
/// the same workspace-wide `shell_init`, so they cannot disagree about what a check
/// is. The file is the source of truth; this type never writes definitions back.
@MainActor
@Observable
final class CheckSupervisor {
    private var byProject: [UUID: [ManagedProcess]] = [:]
    private let launcher: ProcessLaunching

    init(launcher: ProcessLaunching = PTYProcessLauncher()) {
        self.launcher = launcher
    }

    func checks(for projectId: UUID) -> [ManagedProcess] {
        (byProject[projectId] ?? []).sorted { $0.name < $1.name }
    }

    func check(projectId: UUID, name: String) -> ManagedProcess? {
        byProject[projectId]?.first { $0.name == name }
    }

    /// A check is a `short_running` process. A `CheckConfig` has only a command (its
    /// `message` and `watch` belong to the marker path, not the run), so the mapping
    /// is simpler than a test's: no env, no per-check `shell_init`. The workspace-wide
    /// lines are folded in per launch by `ManagedProcess`, as for tests and processes.
    private func processConfig(_ def: CheckConfig) -> ProcessConfig {
        ProcessConfig(command: def.command, kind: .shortRunning)
    }

    /// Reconciles check definitions for one workspace: adds new, updates existing,
    /// drops removed. Checks are not daemons and never auto-start, so a removed
    /// definition is simply dropped (any in-flight run is torn down).
    func apply(
        _ config: WorkspaceConfig?,
        projectId: UUID,
        directory: URL,
        variables: @escaping @MainActor () -> [String: String] = { [:] }
    ) {
        let defined = config?.checks ?? [:]
        let current = byProject[projectId] ?? []
        let global = config?.shellInit ?? []

        var kept: [ManagedProcess] = []
        for check in current {
            if let def = defined[check.name] {
                check.updateDefinition(processConfig(def), globalShellInit: global)
                kept.append(check)
            } else {
                check.kill() // drop: stop any in-flight run
            }
        }

        let existingNames = Set(kept.map(\.name))
        for (name, def) in defined where !existingNames.contains(name) {
            kept.append(ManagedProcess(
                name: name, config: processConfig(def), globalShellInit: global,
                directory: directory, launcher: launcher, variables: variables
            ))
        }

        byProject[projectId] = kept
    }

    /// Starts one check and reports whether it actually launched. `start()` refuses a
    /// check that is already in flight; an unknown name returns false rather than
    /// throwing.
    @discardableResult
    func run(projectId: UUID, name: String) -> Bool {
        guard let check = check(projectId: projectId, name: name) else { return false }
        return check.start()
    }

    /// A `CheckConfig` never defines a `stop` command, so `kill()` alone is the full
    /// teardown, the same as a test.
    func removeWorkspace(_ projectId: UUID) {
        byProject[projectId]?.forEach { $0.kill() }
        byProject[projectId] = nil
    }
}
