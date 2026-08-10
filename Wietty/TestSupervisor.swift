import Foundation
import Observation

/// Owns the test-processes of every workspace and reconciles them against the
/// on-disk `tests` definitions. Tests are run-to-completion checks executed by a
/// `ManagedProcess` in `short_running` mode; this type keeps them separate from
/// the regular process rows and adds manual run / run-all controls. The file is
/// the source of truth; this type never writes definitions back. Staleness (a
/// passing test going neutral when the working tree changes) is tracked via
/// `applyWorkingTreeFingerprint`.
@MainActor
@Observable
final class TestSupervisor {
    private var byProject: [UUID: [ManagedProcess]] = [:]
    private let launcher: ProcessLaunching

    /// Latest working-tree fingerprint observed per workspace (nil until the
    /// first `.workingTree` check runs).
    private var currentFingerprint: [UUID: String] = [:]
    /// The fingerprint stamped when each test was last run (the working-tree
    /// state that run reflects). Keyed by project then test name. A nil entry
    /// means "not yet baselined".
    private var runFingerprint: [UUID: [String: String]] = [:]

    init(launcher: ProcessLaunching = PTYProcessLauncher()) {
        self.launcher = launcher
    }

    func tests(for projectId: UUID) -> [ManagedProcess] {
        (byProject[projectId] ?? []).sorted { $0.name < $1.name }
    }

    func test(projectId: UUID, name: String) -> ManagedProcess? {
        byProject[projectId]?.first { $0.name == name }
    }

    /// A test is a `short_running` process. Maps a `TestConfig` to the
    /// `ProcessConfig` the runner understands, carrying the test's own
    /// `shell_init` across unchanged. The workspace-wide lines are not folded in
    /// here: as in `ProcessSupervisor`, they travel alongside the definition and
    /// `ManagedProcess` merges them per launch.
    private func processConfig(_ def: TestConfig) -> ProcessConfig {
        ProcessConfig(
            command: def.command, kind: .shortRunning, env: def.env,
            allowEmptyVars: def.allowEmptyVars, shellInit: def.shellInit
        )
    }

    /// Reconciles test definitions for one workspace: adds new, updates existing,
    /// drops removed. Tests are not daemons and never auto-start, so a removed
    /// definition is simply dropped (any in-flight run is torn down).
    func apply(
        _ config: WorkspaceConfig?,
        projectId: UUID,
        directory: URL,
        variables: @escaping @MainActor () -> [String: String] = { [:] }
    ) {
        let defined = config?.tests ?? [:]
        let current = byProject[projectId] ?? []
        let global = config?.shellInit ?? []

        var kept: [ManagedProcess] = []
        for test in current {
            if let def = defined[test.name] {
                test.updateDefinition(processConfig(def), globalShellInit: global)
                kept.append(test)
            } else {
                test.kill() // drop: stop any in-flight run
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

    func run(projectId: UUID, name: String) {
        guard let test = test(projectId: projectId, name: name) else { return }
        runFingerprint[projectId, default: [:]][name] = currentFingerprint[projectId]
        test.start()
    }

    func runAll(projectId: UUID) {
        for test in byProject[projectId] ?? [] { run(projectId: projectId, name: test.name) }
    }

    /// Records the workspace's latest working-tree fingerprint and stales any
    /// passing test whose baseline differs. A `.finished` test with no baseline
    /// yet adopts this fingerprint (stays fresh) rather than being reset, so a
    /// test that passed before the first fingerprint was known is not spuriously
    /// staled. Failing tests are never touched here; they clear only by passing.
    func applyWorkingTreeFingerprint(_ fingerprint: String, projectId: UUID) {
        currentFingerprint[projectId] = fingerprint
        for test in byProject[projectId] ?? [] where test.state == .finished {
            let stamped = runFingerprint[projectId]?[test.name]
            if stamped == nil {
                runFingerprint[projectId, default: [:]][test.name] = fingerprint
            } else if stamped != fingerprint {
                test.resetToIdleIfFinished()
            }
        }
    }

    /// A `TestConfig` never defines a `stop` command, so `kill()` alone is the
    /// full teardown (unlike `ProcessSupervisor`, which also runs `stop()` for
    /// daemons).
    func removeWorkspace(_ projectId: UUID) {
        byProject[projectId]?.forEach { $0.kill() }
        byProject[projectId] = nil
        currentFingerprint[projectId] = nil
        runFingerprint[projectId] = nil
    }
}
