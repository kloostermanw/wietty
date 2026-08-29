import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct TestSupervisorTests {
    let dir = URL(fileURLWithPath: "/tmp")
    let pid = UUID()

    private func config(_ tests: [String: TestConfig]) -> WorkspaceConfig {
        WorkspaceConfig(name: nil, agents: [], terminals: [], tests: tests)
    }

    @Test func foldsWorkspaceShellInitInAheadOfTheTestsOwnLines() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            tests: ["unit": TestConfig(command: "phpunit", shellInit: ["source ./.venv/bin/activate"])],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        sup.apply(config, projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "unit")
        #expect(launcher.last.command == "export PATH=$HOME/bin:$PATH\nsource ./.venv/bin/activate\nphpunit")
    }

    @Test func workspaceShellInitReachesATestThatDefinesNone() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            tests: ["unit": TestConfig(command: "phpunit")],
            shellInit: ["export A=1"]
        )
        sup.apply(config, projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "unit")
        #expect(launcher.last.command == "export A=1\nphpunit")
    }

    /// `apply` runs on every config change, so re-applying the same file must not
    /// accumulate the workspace-wide lines the way merging them into the
    /// definition would.
    @Test func reapplyingTheSameConfigDoesNotAccumulateTheWorkspacePrelude() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            tests: ["unit": TestConfig(command: "phpunit", shellInit: ["export B=2"])],
            shellInit: ["export A=1"]
        )
        sup.apply(config, projectId: pid, directory: dir)
        sup.apply(config, projectId: pid, directory: dir)
        sup.apply(config, projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "unit")
        #expect(launcher.last.command == "export A=1\nexport B=2\nphpunit")
    }

    @Test func applyAddsTestsSortedByName() {
        let sup = TestSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["zeta": TestConfig(command: "z"), "alpha": TestConfig(command: "a")]), projectId: pid, directory: dir)
        #expect(sup.tests(for: pid).map(\.name) == ["alpha", "zeta"])
    }

    @Test func applyUpdatesAndDropsDefinitions() {
        let sup = TestSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["a": TestConfig(command: "a"), "b": TestConfig(command: "b")]), projectId: pid, directory: dir)
        sup.apply(config(["a": TestConfig(command: "a2")]), projectId: pid, directory: dir)
        #expect(sup.tests(for: pid).map(\.name) == ["a"])
        #expect(sup.test(projectId: pid, name: "a")?.config.command == "a2")
    }

    @Test func applyKillsARunningTestWhenItsDefinitionIsDropped() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["a": TestConfig(command: "a"), "b": TestConfig(command: "b")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "b")
        #expect(sup.test(projectId: pid, name: "b")?.state == .running)
        sup.apply(config(["a": TestConfig(command: "a")]), projectId: pid, directory: dir)
        #expect(launcher.last.handle.signals.contains(SIGKILL))
        #expect(sup.tests(for: pid).map(\.name) == ["a"])
    }

    @Test func testsDoNotAutoStart() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        #expect(launcher.launches.isEmpty)
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }

    @Test func runStartsOneTest() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan analyse")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "phpstan")
        #expect(launcher.launches.map(\.command).contains("phpstan analyse"))
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .running)
    }

    @Test func runAllStartsEveryTest() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["a": TestConfig(command: "cmd-a"), "b": TestConfig(command: "cmd-b")]), projectId: pid, directory: dir)
        sup.runAll(projectId: pid)
        #expect(launcher.launches.map(\.command).sorted() == ["cmd-a", "cmd-b"])
        #expect(sup.tests(for: pid).allSatisfy { $0.state == .running })
    }

    @Test func runReportsWhetherItStartedTheTest() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        #expect(sup.run(projectId: pid, name: "phpstan") == true)
        #expect(sup.run(projectId: pid, name: "phpstan") == false) // already in flight
        #expect(sup.run(projectId: pid, name: "ghost") == false)   // no such test
        #expect(launcher.launches.count == 1)
    }

    @Test func runAllReportsOnlyTheTestsItStarted() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["a": TestConfig(command: "cmd-a"), "b": TestConfig(command: "cmd-b")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "a")
        #expect(sup.runAll(projectId: pid) == ["b"])
    }

    /// A `run` the guard refuses must not rebase the staleness baseline. Stamping the
    /// current tree for a launch that never happened lets the in-flight run, started
    /// against an older tree, finish green and pass as fresh against the newer one,
    /// which is exactly what the fingerprint exists to prevent.
    @Test func aRefusedRunDoesNotRebaseTheFingerprint() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid)
        sup.run(projectId: pid, name: "phpstan") // launched against fp1
        sup.applyWorkingTreeFingerprint("fp2", projectId: pid) // tree edited mid-run
        sup.run(projectId: pid, name: "phpstan") // refused: still running
        #expect(launcher.launches.count == 1)
        launcher.last.onExit(0)
        sup.applyWorkingTreeFingerprint("fp2", projectId: pid)
        // The result reflects fp1, not the fp2 tree, so it must read as stale.
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }

    @Test func appliesVariablesToTestLaunch() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(
            config(["t": TestConfig(command: "run")]),
            projectId: pid, directory: dir,
            variables: { ["WIETTY_WORKSPACE_PATH": "/repos/app"] }
        )
        sup.run(projectId: pid, name: "t")
        #expect(launcher.last.environment["WIETTY_WORKSPACE_PATH"] == "/repos/app")
    }

    @Test func removeWorkspaceKillsRunningTestsAndDropsThem() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["t": TestConfig(command: "run")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "t")
        #expect(sup.test(projectId: pid, name: "t")?.state == .running)
        sup.removeWorkspace(pid)
        #expect(launcher.last.handle.signals.contains(SIGKILL))
        #expect(sup.tests(for: pid).isEmpty)
    }

    private func passedTest(_ sup: TestSupervisor, launcher: FakeProcessLauncher, name: String) {
        sup.run(projectId: pid, name: name)
        launcher.launches.first { $0.command == sup.test(projectId: pid, name: name)?.config.command }?.onExit(0)
    }

    @Test func changedFingerprintMakesPassedTestStale() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid)
        sup.run(projectId: pid, name: "phpstan")
        launcher.last.onExit(0)
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .finished)
        sup.applyWorkingTreeFingerprint("fp2", projectId: pid) // tree changed
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }

    @Test func changedFingerprintMakesTestRunViaRunAllStale() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid)
        sup.runAll(projectId: pid)
        launcher.last.onExit(0)
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .finished)
        sup.applyWorkingTreeFingerprint("fp2", projectId: pid) // tree changed
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }

    @Test func sameFingerprintKeepsPassedTestFresh() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid)
        sup.run(projectId: pid, name: "phpstan")
        launcher.last.onExit(0)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid) // unchanged
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .finished)
    }

    @Test func failedTestIsNotResetByFingerprintChange() {
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid)
        sup.run(projectId: pid, name: "phpstan")
        launcher.last.onExit(1) // failed
        sup.applyWorkingTreeFingerprint("fp2", projectId: pid)
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .failed(1))
    }

    @Test func firstFingerprintAfterPassIsAdoptedAsBaseline() {
        // Test passes before any fingerprint is known (nil stamp); the first
        // observed fingerprint is adopted, so the test is not spuriously staled.
        let launcher = FakeProcessLauncher()
        let sup = TestSupervisor(launcher: launcher)
        sup.apply(config(["phpstan": TestConfig(command: "phpstan")]), projectId: pid, directory: dir)
        sup.run(projectId: pid, name: "phpstan")
        launcher.last.onExit(0)
        sup.applyWorkingTreeFingerprint("fp1", projectId: pid) // first fingerprint ever
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .finished)
        sup.applyWorkingTreeFingerprint("fp2", projectId: pid) // now a real change
        #expect(sup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }
}
