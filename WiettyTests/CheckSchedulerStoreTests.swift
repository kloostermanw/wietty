import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct CheckSchedulerStoreTests {
    // A provider that records which checks were called and returns canned slices.
    final class RecordingProvider: GitInfoProviding, @unchecked Sendable {
        var gitSyncCalls = 0, prCalls = 0, ciCalls = 0
        func gitSync(for folder: URL) async -> GitSync? {
            gitSyncCalls += 1
            return GitSync(branch: "feature/issue-1", behind: 0, ahead: 0, hasUpstream: true,
                           upstreamRef: "origin/feature/issue-1", baseAhead: 0, baseBehind: 0,
                           hasBase: false, baseRef: nil, owner: "o", repo: "r", issueNumber: 1)
        }
        func pullRequestNumber(for folder: URL, branch: String) async -> Int? { prCalls += 1; return 7 }
        func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? {
            ciCalls += 1
            return ChecksSummary(passing: 1, failing: 0, cancelled: 0, skipped: 0, pending: 0)
        }
    }

    // A provider whose PR lookup can flip from open to closed, to test that a
    // vanished PR clears the stale CI summary along with it.
    final class PRClosingProvider: GitInfoProviding, @unchecked Sendable {
        var prClosed = false
        func gitSync(for folder: URL) async -> GitSync? {
            GitSync(branch: "feature/issue-9", behind: 0, ahead: 0, hasUpstream: true,
                    upstreamRef: "origin/feature/issue-9", baseAhead: 0, baseBehind: 0,
                    hasBase: false, baseRef: nil, owner: "o", repo: "r", issueNumber: 9)
        }
        func pullRequestNumber(for folder: URL, branch: String) async -> Int? { prClosed ? nil : 7 }
        func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? {
            ChecksSummary(passing: 1, failing: 0, cancelled: 0, skipped: 0, pending: 1)
        }
    }

    // A provider with no open PR whose branch head has checks, to test the
    // no-PR fallback. The PR-scoped `ciChecks` returns a distinct summary that
    // must not be used, proving the store took the branch path.
    final class BranchChecksProvider: GitInfoProviding, @unchecked Sendable {
        var branchCalls = 0
        func gitSync(for folder: URL) async -> GitSync? {
            GitSync(branch: "feature/issue-30", behind: 0, ahead: 0, hasUpstream: true,
                    upstreamRef: "origin/feature/issue-30", baseAhead: 0, baseBehind: 0,
                    hasBase: false, baseRef: nil, owner: "o", repo: "r", issueNumber: 30)
        }
        func pullRequestNumber(for folder: URL, branch: String) async -> Int? { nil }
        func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? {
            ChecksSummary(passing: 9, failing: 9, cancelled: 9, skipped: 9, pending: 9)
        }
        func ciChecks(for folder: URL, branch: String) async -> ChecksSummary? {
            branchCalls += 1
            return ChecksSummary(passing: 2, failing: 1, cancelled: 0, skipped: 0, pending: 0)
        }
    }

    private func makeStore(_ provider: GitInfoProviding) -> ProjectStore {
        ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                     service: FakeTerminalService(), gitProvider: provider)
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func runDueChecksPopulatesGitInfoOnFirstRun() async {
        let provider = RecordingProvider()
        let store = makeStore(provider)
        // The fake provider ignores the URL, but the store still needs a real
        // (bookmarkable) directory to add a project.
        store.addProject(url: makeTempDir())
        let project = store.projects[0]
        await store.runDueChecks(now: Date(timeIntervalSince1970: 1000))
        #expect(provider.gitSyncCalls == 1)
        #expect(store.gitInfo[project.id]?.prNumber == 7)
        #expect(store.gitInfo[project.id]?.checks?.passing == 1)
    }

    @Test func branchWithoutPullRequestShowsChecksFromHead() async {
        let provider = BranchChecksProvider()
        let store = makeStore(provider)
        store.addProject(url: makeTempDir())
        let project = store.projects[0]
        await store.runDueChecks(now: Date(timeIntervalSince1970: 1000))
        #expect(store.gitInfo[project.id]?.prNumber == nil)
        #expect(store.gitInfo[project.id]?.checks?.passing == 2)   // branch source, not the PR-scoped 9s
        #expect(store.gitInfo[project.id]?.checks?.failing == 1)
        #expect(provider.branchCalls == 1)
    }

    @Test func checksNotRerunBeforeTheirIntervalElapses() async {
        let provider = RecordingProvider()
        let store = makeStore(provider)
        store.checkIntervals = CheckIntervals(fast: 10, normal: 20, slow: 30)
        store.addProject(url: makeTempDir())
        let t0 = Date(timeIntervalSince1970: 1000)
        await store.runDueChecks(now: t0)                    // expanded project -> Normal (20s)
        await store.runDueChecks(now: t0.addingTimeInterval(5))   // not due yet
        #expect(provider.gitSyncCalls == 1)
        await store.runDueChecks(now: t0.addingTimeInterval(21))  // due again
        #expect(provider.gitSyncCalls == 2)
    }

    @Test func gitDirChangePokeForcesGitSyncBeforeInterval() async {
        let provider = RecordingProvider()
        let store = makeStore(provider)
        store.checkIntervals = CheckIntervals(fast: 10, normal: 20, slow: 30)
        store.addProject(url: makeTempDir())
        let id = store.projects[0].id
        let t0 = Date(timeIntervalSince1970: 1000)
        await store.runDueChecks(now: t0)                    // gitSync runs once
        #expect(provider.gitSyncCalls == 1)

        // A poke only 1s later is well inside the Normal (20s) interval, so it
        // re-runs gitSync only because the poke marks it due again.
        await store.gitDirDidChange(id, now: t0.addingTimeInterval(1))
        #expect(provider.gitSyncCalls == 2)
    }

    @Test func gitDirChangeForUnknownProjectIsNoOp() async {
        let provider = RecordingProvider()
        let store = makeStore(provider)
        store.checkIntervals = CheckIntervals(fast: 10, normal: 20, slow: 30)
        store.addProject(url: makeTempDir())
        let t0 = Date(timeIntervalSince1970: 1000)
        await store.runDueChecks(now: t0)
        let before = provider.gitSyncCalls
        await store.gitDirDidChange(UUID(), now: t0.addingTimeInterval(1))  // no such project
        #expect(provider.gitSyncCalls == before)
    }

    @Test func closedPullRequestClearsStaleCIChecks() async {
        let provider = PRClosingProvider()
        let store = makeStore(provider)
        store.checkIntervals = CheckIntervals(fast: 10, normal: 20, slow: 30)
        store.addProject(url: makeTempDir())
        let project = store.projects[0]
        let t0 = Date(timeIntervalSince1970: 1000)
        await store.runDueChecks(now: t0)
        #expect(store.gitInfo[project.id]?.prNumber == 7)
        #expect(store.gitInfo[project.id]?.checks != nil)

        provider.prClosed = true
        await store.runDueChecks(now: t0.addingTimeInterval(21))  // pullRequest (Normal) due again
        #expect(store.gitInfo[project.id]?.prNumber == nil)
        #expect(store.gitInfo[project.id]?.checks == nil)
    }
}
