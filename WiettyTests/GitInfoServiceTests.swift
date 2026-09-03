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

    @Test func ciChecksForBranchQueriesRollupAndMergesBothNodeKinds() async {
        // The branch-head fallback runs one `gh api graphql` statusCheckRollup
        // query, which already merges CheckRun and StatusContext nodes (the way
        // `gh pr checks` and GitHub's UI do), so no second request or add.
        let svc = service { _, args in
            if args.contains("graphql") {
                return CommandResult(
                    stdout: #"{"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null},{"__typename":"StatusContext","state":"SUCCESS"}]}}}}}}"#,
                    stderr: "", status: 0
                )
            }
            return CommandResult(stdout: "", stderr: "", status: 1)
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks?.passing == 2)   // one CheckRun + one StatusContext
        #expect(checks?.pending == 1)
        #expect(checks?.total == 3)
    }

    @Test func ciChecksForBranchNilWhenRequestFails() async {
        // A transient/auth error (or a repo that will not resolve) exits non-zero.
        // The line hides rather than showing a partial count. An unpushed branch is
        // not this case: it exits 0 with a null `object`, covered by the
        // null-rollup/null-object parser tests.
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "Not Found", status: 1) }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks == nil)
    }

    @Test func ciChecksForBranchSendsOwnerNameAsFieldsAndBranchRaw() async {
        // owner/name must go through `-F` (gh substitutes the {owner}/{repo}
        // placeholders only in `-F` values), while the branch must go through `-f`
        // as a raw string so a branch named like `123` is not type-coerced.
        final class Recorder: @unchecked Sendable { var args: [String] = [] }
        let recorder = Recorder()
        let svc = service { _, args in
            recorder.args = args
            return CommandResult(
                stdout: #"{"data":{"repository":{"object":{"statusCheckRollup":null}}}}"#,
                stderr: "", status: 0
            )
        }
        _ = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "123")
        let a = recorder.args
        func value(afterFlag flag: String, field: String) -> String? {
            for i in a.indices where a[i] == flag && i + 1 < a.count && a[i + 1].hasPrefix("\(field)=") {
                return String(a[i + 1].dropFirst(field.count + 1))
            }
            return nil
        }
        #expect(value(afterFlag: "-F", field: "owner") == "{owner}")
        #expect(value(afterFlag: "-F", field: "name") == "{repo}")
        #expect(value(afterFlag: "-f", field: "branch") == "123")
        #expect(value(afterFlag: "-F", field: "branch") == nil)   // never typed
    }

    @Test func ciChecksForBranchNilWhenRollupIsNull() async {
        // A pushed commit with no checks resolves `statusCheckRollup` to null on a
        // 200; that parses to nil, so the line hides.
        let svc = service { _, args in
            if args.contains("graphql") {
                return CommandResult(
                    stdout: #"{"data":{"repository":{"object":{"statusCheckRollup":null}}}}"#,
                    stderr: "", status: 0
                )
            }
            return CommandResult(stdout: "", stderr: "", status: 1)
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "feature/issue-30")
        #expect(checks == nil)
    }

    @Test func ciChecksForBranchNilForEmptyBranch() async {
        // The empty-branch guard returns nil before any `gh api` call. The runner
        // returns a rollup that would parse to a non-nil summary, so this fails if
        // the guard is ever removed (the call would reach the runner and count it)
        // rather than passing vacuously.
        let svc = service { _, _ in
            CommandResult(
                stdout: #"{"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}}}}}}"#,
                stderr: "", status: 0
            )
        }
        let checks = await svc.ciChecks(for: URL(fileURLWithPath: "/tmp/x"), branch: "")
        #expect(checks == nil)
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
