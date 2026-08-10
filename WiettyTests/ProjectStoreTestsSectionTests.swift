import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct ProjectStoreTestsSectionTests {
    /// A git provider that returns a scriptable fingerprint and nil for the rest.
    struct StubGit: GitInfoProviding {
        let fingerprint: String?
        func gitSync(for folder: URL) async -> GitSync? { nil }
        func pullRequestNumber(for folder: URL, branch: String) async -> Int? { nil }
        func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? { nil }
        func workingTreeFingerprint(for folder: URL) async -> String? { fingerprint }
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
