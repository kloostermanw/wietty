import Testing
import Foundation
@testable import Wietty

struct FakeCommandRunner: CommandRunning {
    let handler: @Sendable (String, [String]) -> CommandResult
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) -> CommandResult {
        handler(executable, arguments)
    }
}

@Suite struct GitInfoServiceTests {
    // "/bin/sh" exists, so ghCandidates resolves and the gh branch runs (the
    // fake runner intercepts the actual invocation).
    private func service(_ handler: @escaping @Sendable (String, [String]) -> CommandResult) -> GitInfoService {
        GitInfoService(runner: FakeCommandRunner(handler: handler), ghCandidates: ["/bin/sh"])
    }

    @Test func assemblesFullGitInfo() async {
        let svc = service { _, args in
            if args.contains("--is-inside-work-tree") { return CommandResult(stdout: "true\n", stderr: "", status: 0) }
            if args.contains("fetch") { return CommandResult(stdout: "", stderr: "", status: 0) }
            if args.contains("--abbrev-ref") { return CommandResult(stdout: "feature/issue-333\n", stderr: "", status: 0) }
            if args.contains("rev-list") { return CommandResult(stdout: "3\t5\n", stderr: "", status: 0) }
            if args.contains("remote") { return CommandResult(stdout: "https://github.com/kloostermanw/wietty.git\n", stderr: "", status: 0) }
            if args.contains("pr") { return CommandResult(stdout: "334\n", stderr: "", status: 0) }
            return CommandResult(stdout: "", stderr: "", status: 1)
        }
        let folder = URL(fileURLWithPath: "/tmp/x")
        let sync = await svc.gitSync(for: folder)
        #expect(sync?.branch == "feature/issue-333")
        #expect(sync?.behind == 3)
        #expect(sync?.ahead == 5)
        #expect(sync?.hasUpstream == true)
        #expect(sync?.issueNumber == 333)
        #expect(sync?.owner == "kloostermanw" && sync?.repo == "wietty")

        let prNumber = await svc.pullRequestNumber(for: folder, branch: sync?.branch ?? "")
        #expect(prNumber == 334)
    }

    @Test func returnsNilForNonRepo() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "fatal: not a git repository", status: 128) }
        let sync = await svc.gitSync(for: URL(fileURLWithPath: "/tmp/x"))
        #expect(sync == nil)
    }

    @Test func noUpstreamHidesCounts() async {
        let svc = service { _, args in
            if args.contains("--is-inside-work-tree") { return CommandResult(stdout: "true", stderr: "", status: 0) }
            if args.contains("--abbrev-ref") { return CommandResult(stdout: "develop", stderr: "", status: 0) }
            if args.contains("rev-list") { return CommandResult(stdout: "", stderr: "no upstream", status: 128) }
            if args.contains("remote") { return CommandResult(stdout: "https://github.com/o/r.git", stderr: "", status: 0) }
            return CommandResult(stdout: "", stderr: "", status: 0) // fetch, pr → empty
        }
        let folder = URL(fileURLWithPath: "/tmp/x")
        let sync = await svc.gitSync(for: folder)
        #expect(sync?.hasUpstream == false)
        #expect(sync?.behind == 0)
        #expect(sync?.ahead == 0)
        #expect(sync?.issueNumber == nil)   // "develop" has no trailing digits

        let prNumber = await svc.pullRequestNumber(for: folder, branch: sync?.branch ?? "")
        #expect(prNumber == nil)      // gh returned empty
    }

    @Test func assemblesBaseAheadBehindAndChecks() async {
        let svc = service { _, args in
            if args.contains("--is-inside-work-tree") { return CommandResult(stdout: "true\n", stderr: "", status: 0) }
            if args.contains(where: { $0.contains("@{upstream}") }) && args.contains("--abbrev-ref") {
                return CommandResult(stdout: "origin/feature/issue-333\n", stderr: "", status: 0)
            }
            if args.contains("--abbrev-ref") { return CommandResult(stdout: "feature/issue-333\n", stderr: "", status: 0) }
            if args.contains("symbolic-ref") { return CommandResult(stdout: "origin/develop\n", stderr: "", status: 0) }
            if args.contains(where: { $0.contains("@{upstream}") }) { return CommandResult(stdout: "1\t2\n", stderr: "", status: 0) }
            if args.contains(where: { $0.contains("origin/develop...HEAD") }) { return CommandResult(stdout: "4\t7\n", stderr: "", status: 0) }
            if args.contains("remote") { return CommandResult(stdout: "https://github.com/o/r.git\n", stderr: "", status: 0) }
            if args.contains("checks") {
                return CommandResult(stdout: "[{\"bucket\":\"pass\"},{\"bucket\":\"fail\"},{\"bucket\":\"skipping\"}]", stderr: "", status: 1)
            }
            if args.contains("pr") { return CommandResult(stdout: "334\n", stderr: "", status: 0) }
            return CommandResult(stdout: "", stderr: "", status: 0)
        }
        let folder = URL(fileURLWithPath: "/tmp/x")
        let sync = await svc.gitSync(for: folder)
        #expect(sync?.hasBase == true)
        #expect(sync?.baseRef == "origin/develop")
        #expect(sync?.upstreamRef == "origin/feature/issue-333")
        #expect(sync?.baseBehind == 4)
        #expect(sync?.baseAhead == 7)
        #expect(sync?.behind == 1)
        #expect(sync?.ahead == 2)

        let prNumber = await svc.pullRequestNumber(for: folder, branch: sync?.branch ?? "")
        #expect(prNumber == 334)
        let checks = await svc.ciChecks(for: folder, prNumber: prNumber ?? 0)
        #expect(checks?.passing == 1)
        #expect(checks?.failing == 1)
        #expect(checks?.skipped == 1)
        #expect(checks?.hasFailures == true)
    }

    @Test func ciChecksForBranchQueriesHeadCommitCheckRuns() async {
        // The branch-head fallback runs `gh api .../commits/<branch>/check-runs`
        // and parses the check-runs shape (not the `gh pr checks` bucket shape).
        let svc = service { _, args in
            if args.contains("api"),
               args.contains(where: { $0.contains("commits/feature/issue-30/check-runs") }) {
                return CommandResult(
                    stdout: #"{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]}"#,
                    stderr: "", status: 0
                )
            }
            // A branch with only check-runs still returns 200 (empty) from the
            // legacy status endpoint; that empty side must not hide the line.
            if args.contains("api"), args.contains(where: { $0.contains("/status?") }) {
                return CommandResult(stdout: #"{"state":"pending","statuses":[]}"#, stderr: "", status: 0)
            }
            return CommandResult(stdout: "", stderr: "", status: 1)
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks?.passing == 1)
        #expect(checks?.pending == 1)
    }

    @Test func ciChecksForBranchUsesLegacyStatusesWhenNoCheckRuns() async {
        // The CircleCI-only case: no check-runs (200 with an empty array), all CI
        // reported through the legacy combined-status endpoint. The summary must
        // come solely from the statuses.
        let svc = service { _, args in
            if args.contains("api"), args.contains(where: { $0.contains("/check-runs") }) {
                return CommandResult(stdout: #"{"total_count":0,"check_runs":[]}"#, stderr: "", status: 0)
            }
            if args.contains("api"), args.contains(where: { $0.contains("/status?") }) {
                return CommandResult(
                    stdout: #"{"state":"failure","statuses":[{"context":"ci/circleci: build","state":"success"},{"context":"ci/circleci: test","state":"failure"}]}"#,
                    stderr: "", status: 0
                )
            }
            return CommandResult(stdout: "", stderr: "", status: 1)
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks?.passing == 1)
        #expect(checks?.failing == 1)
        #expect(checks?.total == 2)
    }

    @Test func ciChecksForBranchNilWhenBothEndpointsFail() async {
        // An unpushed branch 4xxs both endpoints, so every `gh api` call exits
        // non-zero and the line hides.
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "Not Found", status: 1) }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks == nil)
    }

    @Test func ciChecksForBranchHidesLineWhenOneEndpointFailsTransiently() async {
        // If check-runs succeeds but the status endpoint fails (a transient/auth
        // error, not a 404, since a valid commit 200s both), returning only the
        // surviving side would show a smaller count that looks complete. The line
        // hides instead until the next poll.
        let svc = service { _, args in
            if args.contains("api"), args.contains(where: { $0.contains("/check-runs") }) {
                return CommandResult(
                    stdout: #"{"total_count":1,"check_runs":[{"status":"completed","conclusion":"success"}]}"#,
                    stderr: "", status: 0
                )
            }
            return CommandResult(stdout: "", stderr: "500 Internal Server Error", status: 1)
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks == nil)
    }

    @Test func ciChecksForBranchNilForEmptyBranch() async {
        // The empty-branch guard returns nil before any `gh api` call.
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "")
        #expect(checks == nil)
    }

    @Test func ciChecksForBranchMergesCheckRunsWithLegacyStatuses() async {
        // Some CI (e.g. CircleCI) reports via the legacy commit-status API, not
        // check-runs. The branch fallback must merge both, the way the commit's
        // status-details page and `gh pr checks` do.
        let svc = service { _, args in
            if args.contains("api"), args.contains(where: { $0.contains("/check-runs") }) {
                return CommandResult(
                    stdout: #"{"total_count":1,"check_runs":[{"status":"completed","conclusion":"success"}]}"#,
                    stderr: "", status: 0
                )
            }
            if args.contains("api"), args.contains(where: { $0.contains("/status?") }) {
                return CommandResult(
                    stdout: #"{"state":"success","statuses":[{"context":"ci/circleci: build","state":"success"}]}"#,
                    stderr: "", status: 0
                )
            }
            return CommandResult(stdout: "", stderr: "", status: 1)
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks?.passing == 2)   // one check-run + one CircleCI status
        #expect(checks?.total == 2)
    }

    @Test func fingerprintStableForSameTreeState() async {
        let svc = service { _, args in
            if args.contains("--is-inside-work-tree") { return CommandResult(stdout: "true\n", stderr: "", status: 0) }
            if args.contains("status") { return CommandResult(stdout: " M app/Foo.php\n", stderr: "", status: 0) }
            if args.contains("diff") { return CommandResult(stdout: "@@ -1 +1 @@\n-old\n+new\n", stderr: "", status: 0) }
            return CommandResult(stdout: "", stderr: "", status: 0)
        }
        let folder = URL(fileURLWithPath: "/tmp/x")
        let a = await svc.workingTreeFingerprint(for: folder)
        let b = await svc.workingTreeFingerprint(for: folder)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func fingerprintChangesWhenDiffChanges() async {
        let before = "@@ -1 +1 @@\n-old\n+new\n"
        let after = "@@ -1 +2 @@\n-old\n+newer\n+extra\n" // an edit to the already-modified file

        func makeService(withDiff diff: String) -> GitInfoService {
            service { _, args in
                if args.contains("--is-inside-work-tree") { return CommandResult(stdout: "true\n", stderr: "", status: 0) }
                if args.contains("status") { return CommandResult(stdout: " M app/Foo.php\n", stderr: "", status: 0) }
                if args.contains("diff") { return CommandResult(stdout: diff, stderr: "", status: 0) }
                return CommandResult(stdout: "", stderr: "", status: 0)
            }
        }

        let folder = URL(fileURLWithPath: "/tmp/x")
        let beforeFingerprint = await makeService(withDiff: before).workingTreeFingerprint(for: folder)
        let afterFingerprint = await makeService(withDiff: after).workingTreeFingerprint(for: folder)
        #expect(beforeFingerprint != afterFingerprint)
    }

    @Test func fingerprintNilForNonRepo() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "fatal: not a git repository", status: 128) }
        let fp = await svc.workingTreeFingerprint(for: URL(fileURLWithPath: "/tmp/x"))
        #expect(fp == nil)
    }
}
