import Testing
import Foundation
@testable import Wietty

/// The on-demand side of a workspace's `checks`: one `ManagedProcess` per check,
/// run from the card's "Checks" submenu, its output shown in the pane. The scheduled
/// freshness marker is a separate path (`FreshnessService`); this type is only the
/// run-now and open-log half, so it carries none of the marker's watch-file caching.
@MainActor
@Suite struct CheckSupervisorTests {
    let dir = URL(fileURLWithPath: "/tmp")
    let pid = UUID()

    private func config(_ checks: [String: CheckConfig]) -> WorkspaceConfig {
        WorkspaceConfig(name: nil, agents: [], terminals: [], checks: checks)
    }

    @Test func applyAddsChecksSortedByName() {
        let sup = CheckSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["zeta": CheckConfig(command: "z"), "alpha": CheckConfig(command: "a")]),
                  projectId: pid, directory: dir)
        #expect(sup.checks(for: pid).map(\.name) == ["alpha", "zeta"])
    }

    @Test func applyUpdatesAndDropsDefinitions() {
        let sup = CheckSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["a": CheckConfig(command: "a"), "b": CheckConfig(command: "b")]),
                  projectId: pid, directory: dir)
        sup.apply(config(["a": CheckConfig(command: "a2")]), projectId: pid, directory: dir)
        #expect(sup.checks(for: pid).map(\.name) == ["a"])
        #expect(sup.check(projectId: pid, name: "a")?.config.command == "a2")
    }

    @Test func checksDoNotAutoStart() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["lint": CheckConfig(command: "lint")]), projectId: pid, directory: dir)
        #expect(launcher.launches.isEmpty)
        #expect(sup.check(projectId: pid, name: "lint")?.state == .idle)
    }

    @Test func runStartsOneCheck() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["lint": CheckConfig(command: "composer lint")]), projectId: pid, directory: dir)
        #expect(sup.run(projectId: pid, name: "lint") == true)
        #expect(launcher.launches.map(\.command).contains("composer lint"))
        #expect(sup.check(projectId: pid, name: "lint")?.state == .running)
    }

    @Test func runReportsWhetherItStartedTheCheck() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["lint": CheckConfig(command: "lint")]), projectId: pid, directory: dir)
        #expect(sup.run(projectId: pid, name: "lint") == true)
        #expect(sup.run(projectId: pid, name: "lint") == false) // already in flight
        #expect(sup.run(projectId: pid, name: "ghost") == false) // no such check
        #expect(launcher.launches.count == 1)
    }

    /// A check command referencing a `WIETTY_*` variable that is currently unset must
    /// still run, expanding the variable to empty, so the run-now path agrees with the
    /// scheduled `FreshnessService` path (which has no way to block and always expands
    /// empty). A test/process would block here; a check opts into empty expansion.
    @Test func runExpandsUnsetVariablesRatherThanBlocking() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["c": CheckConfig(command: "echo $WIETTY_NOPE")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "c")
        #expect(launcher.launches.map(\.command).contains("echo $WIETTY_NOPE"))
        #expect(sup.check(projectId: pid, name: "c")?.state == .running)
    }

    /// The per-project `WIETTY_*` variables are injected into a check's launch
    /// environment, the same as a test or process, so a check command can read them.
    /// This is the run-now half of the equivalence the type's doc claims: both this
    /// path and `FreshnessService` inject the same variables.
    @Test func appliesVariablesToCheckLaunch() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["c": CheckConfig(command: "run")]), projectId: pid, directory: dir,
                  variables: { ["WIETTY_WORKSPACE_PATH": "/repos/app"] })
        sup.run(projectId: pid, name: "c")
        #expect(launcher.last.environment["WIETTY_WORKSPACE_PATH"] == "/repos/app")
    }

    @Test func foldsWorkspaceShellInitInAheadOfTheCommand() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            checks: ["lint": CheckConfig(command: "composer lint")],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        sup.apply(config, projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "lint")
        #expect(launcher.last.command == "export PATH=$HOME/bin:$PATH\ncomposer lint")
    }

    /// `apply` runs on every config change, so re-applying the same file must not
    /// accumulate the workspace-wide lines.
    @Test func reapplyingTheSameConfigDoesNotAccumulateTheWorkspacePrelude() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            checks: ["lint": CheckConfig(command: "lint")],
            shellInit: ["export A=1"]
        )
        sup.apply(config, projectId: pid, directory: dir)
        sup.apply(config, projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "lint")
        #expect(launcher.last.command == "export A=1\nlint")
    }

    @Test func applyKillsARunningCheckWhenItsDefinitionIsDropped() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["a": CheckConfig(command: "a"), "b": CheckConfig(command: "b")]),
                  projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "b")
        #expect(sup.check(projectId: pid, name: "b")?.state == .running)
        sup.apply(config(["a": CheckConfig(command: "a")]), projectId: pid, directory: dir)
        #expect(launcher.last.handle.signals.contains(SIGKILL))
        #expect(sup.checks(for: pid).map(\.name) == ["a"])
    }

    @Test func removeWorkspaceKillsRunningChecksAndDropsThem() {
        let launcher = FakeProcessLauncher()
        let sup = CheckSupervisor(launcher: launcher)
        sup.apply(config(["a": CheckConfig(command: "run")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "a")
        #expect(sup.check(projectId: pid, name: "a")?.state == .running)
        sup.removeWorkspace(pid)
        #expect(launcher.last.handle.signals.contains(SIGKILL))
        #expect(sup.checks(for: pid).isEmpty)
    }
}
