import Testing
import Foundation
import WiettyShared
@testable import Wietty

/// Minimal `GitInfoProviding` fake for the round trip test below. Distinct from
/// `GitStoreTests.FakeGitInfoProvider` (which hardcodes owner and repo to nil) because
/// this test needs `issueURL` and `prURL` to actually resolve, which requires a non nil
/// owner and repo.
private final class RoundTripGitInfoProvider: GitInfoProviding, @unchecked Sendable {
    var sync: GitSync
    var prNumber: Int?
    var checks: ChecksSummary?

    init(sync: GitSync, prNumber: Int?, checks: ChecksSummary?) {
        self.sync = sync
        self.prNumber = prNumber
        self.checks = checks
    }

    func gitSync(for folder: URL) async -> GitSync? { sync }
    func pullRequestNumber(for folder: URL, branch: String) async -> Int? { prNumber }
    func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? { checks }
}

@MainActor
@Suite struct RemoteProjectAdapterTests {

    // MARK: - Mapping onto the app's local types

    @Test func mapsWorkspacesSessionsAndGitOntoLocalTypes() throws {
        let wsId = UUID()
        let sessionId = UUID()
        let workspace = RemoteWorkspace(
            id: wsId,
            name: "demo",
            sessions: [RemoteSession(id: sessionId, sessionId: "s1", label: "shell",
                                     kind: .claude, isRunning: true, needsAttention: true,
                                     jobName: "vim")],
            git: RemoteGit(branch: "main", ahead: 1, behind: 0, hasUpstream: true,
                           base: RemoteBase(ahead: 4, behind: 2),
                           issueNumber: 29, prNumber: 42,
                           issueURL: URL(string: "https://example.test/issues/29"),
                           prURL: URL(string: "https://example.test/pull/42"),
                           checks: RemoteChecks(passing: 2, failing: 0, cancelled: 0,
                                                skipped: 0, pending: 1, summary: ""))
        )

        let out = RemoteProjectAdapter.decoded([workspace])

        #expect(out.projects.count == 1)
        let project = try #require(out.projects.first)
        #expect(project.id == wsId)
        #expect(project.name == "demo")
        let ref = try #require(project.terminals.first)
        #expect(ref.id == sessionId)
        #expect(ref.sessionId == "s1")
        #expect(ref.label == "shell")
        #expect(ref.kind == .claude)
        #expect(out.runStates[sessionId] == .running)
        #expect(out.attention.contains(sessionId))
        #expect(out.jobNames[sessionId] == "vim")

        let info = try #require(out.gitInfo[wsId])
        #expect(info.branch == "main")
        #expect(info.hasBase)
        #expect(info.baseAhead == 4)
        #expect(info.baseBehind == 2)
        #expect(info.issueNumber == 29)
        #expect(info.prNumber == 42)
        #expect(info.checks?.pending == 1)
    }

    @Test func aWorkspaceWithNoGitHasNoGitInfo() {
        let id = UUID()
        let out = RemoteProjectAdapter.decoded([RemoteWorkspace(id: id, name: "demo")])
        #expect(out.projects.count == 1)
        #expect(out.gitInfo[id] == nil)
    }

    @Test func noBaseLeavesHasBaseFalse() throws {
        let id = UUID()
        let out = RemoteProjectAdapter.decoded([
            RemoteWorkspace(id: id, name: "demo",
                            git: RemoteGit(branch: "main", ahead: 0, behind: 0, hasUpstream: false))
        ])
        let info = try #require(out.gitInfo[id])
        #expect(info.hasBase == false)
    }

    @Test func aNotRunningSessionMapsToExited() {
        let sessionId = UUID()
        let out = RemoteProjectAdapter.decoded([
            RemoteWorkspace(id: UUID(), name: "demo",
                            sessions: [RemoteSession(id: sessionId, sessionId: "s1", label: "shell")])
        ])
        #expect(out.runStates[sessionId] == .exited)
    }

    @Test func aSessionWithNoAttentionIsAbsentFromTheAttentionSet() {
        let sessionId = UUID()
        let out = RemoteProjectAdapter.decoded([
            RemoteWorkspace(id: UUID(), name: "demo",
                            sessions: [RemoteSession(id: sessionId, sessionId: "s1", label: "shell")])
        ])
        #expect(out.attention.isEmpty)
        #expect(out.jobNames.isEmpty)
    }

    // MARK: - Round trip: WorkspaceSerializer -> package decoder -> adapter
    //
    // Builds a real `ProjectStore`, serializes it with the server's
    // `WorkspaceSerializer` (the actual producer used by `RemoteServer`), and decodes the
    // result back through the package. This is the test that catches a key rename on
    // either side: the package's DTOs only work if their property names line up with
    // `WorkspaceSerializer`'s emitted keys, and this fails loudly if they ever drift.

    @Test func roundTripsThroughSerializerAndPackageDecoder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let provider = RoundTripGitInfoProvider(
            sync: GitSync(branch: "feature/round-trip", behind: 2, ahead: 5, hasUpstream: true,
                          upstreamRef: "origin/feature/round-trip", baseAhead: 1, baseBehind: 3,
                          hasBase: true, baseRef: "main", owner: "acme", repo: "widgets",
                          issueNumber: 29),
            prNumber: 42,
            checks: ChecksSummary(passing: 3, failing: 1, cancelled: 0, skipped: 2, pending: 1)
        )
        let store = ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                 service: FakeTerminalService(), gitProvider: provider)
        store.addProject(url: folder)
        let project = store.projects[0]

        await store.refreshAllGitInfo()

        let ref = try await store.openSessionThrowing(for: project, kind: .claude)
        store.handle(.job(sessionId: ref.sessionId, jobName: "2.1.203")) // claude version string: running
        store.handle(.bell(sessionId: ref.sessionId))

        let workspacesValue = WorkspaceSerializer(store: store).workspaces()
        guard case let .object(members) = workspacesValue, let list = members["workspaces"] else {
            Issue.record("WorkspaceSerializer did not produce a workspaces array")
            return
        }
        // Same envelope shape RemoteServer's /control socket sends.
        let envelope = JSONValue.object(["type": .string("snapshot"), "workspaces": list])
        let remote = try #require(RemoteSnapshotDecoder.decode(snapshotText: envelope.encodedString()))
        let decoded = RemoteProjectAdapter.decoded(remote)

        #expect(decoded.projects.count == 1)
        let decodedProject = try #require(decoded.projects.first)
        #expect(decodedProject.id == project.id)
        #expect(decodedProject.name == project.name)
        #expect(decodedProject.terminals.count == 1)
        let decodedRef = try #require(decodedProject.terminals.first)
        #expect(decodedRef.id == ref.id)
        #expect(decodedRef.sessionId == ref.sessionId)
        #expect(decodedRef.label == ref.label)
        #expect(decodedRef.kind == .claude)

        let expected = try #require(store.gitInfo[project.id])
        let gitInfo = try #require(decoded.gitInfo[project.id])
        #expect(gitInfo.branch == expected.branch)
        #expect(gitInfo.ahead == expected.ahead)
        #expect(gitInfo.behind == expected.behind)
        #expect(gitInfo.hasUpstream == expected.hasUpstream)
        #expect(gitInfo.baseAhead == expected.baseAhead)
        #expect(gitInfo.baseBehind == expected.baseBehind)
        #expect(gitInfo.hasBase == expected.hasBase)
        #expect(gitInfo.issueNumber == expected.issueNumber)
        #expect(gitInfo.prNumber == expected.prNumber)
        #expect(gitInfo.issueURL == expected.issueURL)
        #expect(expected.issueURL != nil) // sanity: the field under test is actually populated
        #expect(gitInfo.prURL == expected.prURL)
        #expect(expected.prURL != nil)
        #expect(gitInfo.checks == expected.checks)
        #expect(expected.checks != nil)

        #expect(decoded.runStates[ref.id] == .running)
        #expect(decoded.attention.contains(ref.id))
        #expect(decoded.jobNames[ref.id] == "2.1.203")
    }
}
