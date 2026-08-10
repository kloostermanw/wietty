import Foundation
import Observation

/// Owns the managed processes of every workspace and reconciles them against the
/// on-disk definitions. The file is the source of truth; this type never writes
/// definitions back.
@MainActor
@Observable
final class ProcessSupervisor {
    private var byProject: [UUID: [ManagedProcess]] = [:]
    private let launcher: ProcessLaunching
    private let graceInterval: Duration

    init(launcher: ProcessLaunching = PTYProcessLauncher(), graceInterval: Duration = .seconds(5)) {
        self.launcher = launcher
        self.graceInterval = graceInterval
    }

    func processes(for projectId: UUID) -> [ManagedProcess] {
        (byProject[projectId] ?? []).sorted { $0.name < $1.name }
    }

    func process(projectId: UUID, name: String) -> ManagedProcess? {
        byProject[projectId]?.first { $0.name == name }
    }

    /// Reconciles process definitions for one workspace: adds new, updates
    /// existing, drops removed (or orphans them if still running), auto-starts
    /// new definitions (probing already-up daemons first).
    func apply(
        _ config: WorkspaceConfig?,
        projectId: UUID,
        directory: URL,
        variables: @escaping @MainActor () -> [String: String] = { [:] }
    ) {
        let defined = config?.processes ?? [:]
        let current = byProject[projectId] ?? []
        // The workspace-wide prelude travels alongside each definition rather than
        // being merged into it. The store rewrites `wietty.json` from the
        // decoded definitions it keeps on `Project`, so a merged definition would
        // duplicate the global lines into every process on disk. `ManagedProcess`
        // merges the two per launch, which also keeps `ProcessConfig.shellInit`
        // meaning one thing wherever it is read.
        let global = config?.shellInit ?? []

        // Update or drop existing.
        var kept: [ManagedProcess] = []
        for process in current {
            if let def = defined[process.name] {
                process.updateDefinition(def, globalShellInit: global)
                kept.append(process)
            } else if process.state == .running || process.state == .orphaned || process.state == .starting || process.state == .stopping {
                process.markOrphaned()
                kept.append(process)
            }
            // else: idle/finished/failed and no longer defined -> drop.
        }

        // Add new definitions.
        let existingNames = Set(kept.map(\.name))
        for (name, def) in defined where !existingNames.contains(name) {
            let process = ManagedProcess(
                name: name, config: def, globalShellInit: global, directory: directory,
                launcher: launcher, graceInterval: graceInterval,
                variables: variables
            )
            kept.append(process)
            if def.autoStart { autoStart(process) }
        }

        byProject[projectId] = kept
    }

    /// Re-probes every daemon that has a status command.
    func refreshStatuses() {
        for processes in byProject.values {
            for process in processes where process.config.kind == .daemon && process.config.status != nil {
                process.probeStatus()
            }
        }
    }

    /// Re-probes the status-bearing daemons of one workspace only.
    func refreshStatusesForWorkspace(_ projectId: UUID) {
        for process in byProject[projectId] ?? [] where process.config.kind == .daemon && process.config.status != nil {
            process.probeStatus()
        }
    }

    func removeWorkspace(_ projectId: UUID) {
        // Tear down both process kinds synchronously before dropping the map
        // entry. A daemon's start command has already exited (no live
        // handle), so `stop()` -- which runs its configured `stop` command --
        // is what actually brings the backing service down; the spawned stop
        // subprocess runs to completion independently of this ManagedProcess,
        // so it isn't lost when the map entry is cleared. `kill()` then
        // SIGKILLs any live handle immediately and synchronously, which is
        // the effective teardown for a long-running process (a harmless
        // no-op for a daemon with no live handle). Any escalation `Task`
        // `stop()` may have started would not survive deallocation, hence
        // the synchronous `kill()` as a backstop.
        byProject[projectId]?.forEach {
            $0.stop()
            $0.kill()
        }
        byProject[projectId] = nil
    }

    /// Starts a newly-added process, probing daemons with a status command
    /// first so an already-up daemon isn't relaunched. With the fake launcher
    /// used in tests the probe's exit lands synchronously, so `process.state`
    /// is already `.running` here. With a real (async) launcher the probe
    /// result lands later, so this races and the start command may still run
    /// against an already-up daemon; that's harmless because daemon start
    /// commands are expected to be idempotent (e.g. `sail up -d` on an already
    /// up stack is a no-op).
    private func autoStart(_ process: ManagedProcess) {
        if process.config.kind == .daemon, process.config.status != nil {
            process.probeStatus()
            if process.state == .running { return }
        }
        process.start()
    }
}
