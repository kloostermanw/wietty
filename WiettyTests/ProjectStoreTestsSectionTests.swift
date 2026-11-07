import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct ProjectStoreTestsSectionTests {
    /// A git provider that returns a scriptable fingerprint and nil for the rest.
    struct StubGit: GitInfoProviding {
        let fingerprint: String?
        var uncommitted = 0
        var sync: GitSync? = nil
        func gitSync(for folder: URL) async -> GitSync? { sync }
        func pullRequestNumber(for folder: URL, branch: String) async -> Int? { nil }
        func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? { nil }
        func workingTreeState(for folder: URL) async -> WorkingTreeState? {
            fingerprint.map { WorkingTreeState(fingerprint: $0, uncommitted: uncommitted) }
        }
    }

    private static let developSync = GitSync(
        branch: "develop", behind: 0, ahead: 0, hasUpstream: true, upstreamRef: "origin/develop",
        baseAhead: 0, baseBehind: 0, hasBase: false, baseRef: nil, owner: nil, repo: nil, issueNumber: nil
    )

    /// A cold refresh lands the uncommitted count in `gitInfo`: `.gitSync` runs
    /// before `.workingTree` in a pass, so the entry exists when the count arrives
    /// and the first refresh does not drop it. The fingerprint still reaches the
    /// test supervisor. Issue #81.
    @Test func workingTreeCheckWritesUncommittedCountIntoGitInfo() async {
        let launcher = FakeProcessLauncher()
        let testSup = TestSupervisor(launcher: launcher)
        let store = ProjectStore(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
            service: FakeTerminalService(),
            gitProvider: StubGit(fingerprint: "fp-A", uncommitted: 10, sync: Self.developSync),
            testSupervisor: testSup
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.addProject(url: folder)
        let pid = store.projects[0].id
        testSup.apply(
            WorkspaceConfig(name: nil, agents: [], terminals: [], tests: ["phpstan": TestConfig(command: "phpstan")]),
            projectId: pid, directory: folder
        )
        testSup.run(projectId: pid, name: "phpstan")
        launcher.last.onExit(0)

        await store.refreshAllGitInfo()

        #expect(store.gitInfo[pid]?.uncommitted == 10)
        #expect(store.gitInfo[pid]?.branch == "develop")
        // The fingerprint was forwarded: a different one now stales the passed test.
        store.forwardWorkingTreeFingerprint("fp-B", projectId: pid)
        #expect(testSup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }

    @Test func workingTreeCheckForwardsFingerprintToTestSupervisor() async {
        let launcher = FakeProcessLauncher()
        let testSup = TestSupervisor(launcher: launcher)
        let store = ProjectStore(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
            service: FakeTerminalService(),
            gitProvider: StubGit(fingerprint: "fp-A"),
            testSupervisor: testSup
        )
        // A project whose tests are applied directly (no real config file needed).
        let pid = UUID()
        let dir = URL(fileURLWithPath: "/tmp")
        testSup.apply(
            WorkspaceConfig(name: nil, agents: [], terminals: [], tests: ["phpstan": TestConfig(command: "phpstan")]),
            projectId: pid, directory: dir
        )
        testSup.run(projectId: pid, name: "phpstan")
        launcher.last.onExit(0)
        #expect(testSup.test(projectId: pid, name: "phpstan")?.state == .finished)
        // Push a *different* fingerprint via the store's public forwarding hook.
        store.forwardWorkingTreeFingerprint("fp-A", projectId: pid)   // baseline adopt
        store.forwardWorkingTreeFingerprint("fp-B", projectId: pid)   // change -> stale
        #expect(testSup.test(projectId: pid, name: "phpstan")?.state == .idle)
    }
}
