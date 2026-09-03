import Testing
import Foundation
@testable import Wietty

@Suite struct GitParsingTests {
    @Test func issueNumberFromTrailingDigits() {
        #expect(GitParsing.issueNumber(fromBranch: "feature/issue-333") == 333)
        #expect(GitParsing.issueNumber(fromBranch: "hotfix/456") == 456)
    }

    @Test func issueNumberNilWhenNoTrailingDigits() {
        #expect(GitParsing.issueNumber(fromBranch: "develop") == nil)
        #expect(GitParsing.issueNumber(fromBranch: "main") == nil)
        #expect(GitParsing.issueNumber(fromBranch: "feature/v2-release") == nil)
        #expect(GitParsing.issueNumber(fromBranch: "feature/issue-") == nil)
    }

    @Test func aheadBehindParsesTwoIntegers() {
        #expect(GitParsing.aheadBehind(fromRevListOutput: "3\t5") ?? (-1, -1) == (3, 5))
        #expect(GitParsing.aheadBehind(fromRevListOutput: "0 0\n") ?? (-1, -1) == (0, 0))
    }

    @Test func aheadBehindNilOnMalformed() {
        #expect(GitParsing.aheadBehind(fromRevListOutput: "") == nil)
        #expect(GitParsing.aheadBehind(fromRevListOutput: "x y") == nil)
        #expect(GitParsing.aheadBehind(fromRevListOutput: "3") == nil)
    }

    @Test func ownerRepoFromHTTPSandSSH() {
        let https = GitParsing.ownerRepo(fromRemoteURL: "https://github.com/kloostermanw/wietty.git")
        #expect(https?.owner == "kloostermanw")
        #expect(https?.repo == "wietty")
        let ssh = GitParsing.ownerRepo(fromRemoteURL: "git@github.com:kloostermanw/wietty.git")
        #expect(ssh?.owner == "kloostermanw")
        #expect(ssh?.repo == "wietty")
    }

    @Test func ownerRepoNilForNonGitHub() {
        #expect(GitParsing.ownerRepo(fromRemoteURL: "https://gitlab.com/a/b.git") == nil)
        #expect(GitParsing.ownerRepo(fromRemoteURL: "not a url") == nil)
    }

    @Test func checksSummaryTotalsAndFailures() {
        let s = ChecksSummary(passing: 291, failing: 11, cancelled: 3, skipped: 3, pending: 0)
        #expect(s.total == 308)
        #expect(s.hasFailures == true)
        let clean = ChecksSummary(passing: 291, failing: 0, cancelled: 0, skipped: 3, pending: 0)
        #expect(clean.hasFailures == false)
        #expect(clean.total == 294)
    }

    @Test func defaultBranchStripsOriginPrefix() {
        #expect(GitParsing.defaultBranch(fromSymbolicRef: "origin/develop\n") == "develop")
        #expect(GitParsing.defaultBranch(fromSymbolicRef: "refs/remotes/origin/main") == "main")
        #expect(GitParsing.defaultBranch(fromSymbolicRef: "") == nil)
    }

    @Test func checksSummaryTalliesBuckets() {
        let json = """
        [{"bucket":"pass"},{"bucket":"pass"},{"bucket":"fail"},{"bucket":"cancel"},{"bucket":"skipping"},{"bucket":"pending"}]
        """
        let s = GitParsing.checksSummary(fromBucketJSON: json)
        #expect(s?.passing == 2)
        #expect(s?.failing == 1)
        #expect(s?.cancelled == 1)
        #expect(s?.skipped == 1)
        #expect(s?.pending == 1)
    }

    @Test func checksSummaryNilOnEmptyOrInvalid() {
        #expect(GitParsing.checksSummary(fromBucketJSON: "") == nil)
        #expect(GitParsing.checksSummary(fromBucketJSON: "not json") == nil)
        #expect(GitParsing.checksSummary(fromBucketJSON: "[]") == nil)
    }

    @Test func checksSummaryFromRollupMergesCheckRunsAndStatusContexts() {
        // The GraphQL rollup returns both CheckRun and StatusContext nodes in one
        // `contexts` list (uppercase enums), already deduped to the latest per
        // suite and context. One parser buckets both.
        let json = """
        {"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"TIMED_OUT"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
          {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null},
          {"__typename":"StatusContext","state":"SUCCESS"},
          {"__typename":"StatusContext","state":"PENDING"},
          {"__typename":"StatusContext","state":"FAILURE"},
          {"__typename":"StatusContext","state":"ERROR"}
        ]}}}}}}
        """
        let s = GitParsing.checksSummary(fromRollupJSON: json)
        #expect(s?.passing == 3)    // CheckRun SUCCESS + NEUTRAL, StatusContext SUCCESS
        #expect(s?.failing == 4)    // CheckRun FAILURE + TIMED_OUT, StatusContext FAILURE + ERROR
        #expect(s?.cancelled == 1)
        #expect(s?.skipped == 1)
        #expect(s?.pending == 2)    // CheckRun IN_PROGRESS, StatusContext PENDING
    }

    @Test func checksSummaryFromRollupMatchesGitHubRollupExample() {
        // The `celery-my` develop case from issue #63: GitHub's rollup for commit
        // 1dd340b is 5 all-green contexts (3 CheckRun + 2 CircleCI StatusContext).
        let json = """
        {"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"StatusContext","state":"SUCCESS"},
          {"__typename":"StatusContext","state":"SUCCESS"}
        ]}}}}}}
        """
        let s = GitParsing.checksSummary(fromRollupJSON: json)
        #expect(s?.passing == 5)
        #expect(s?.total == 5)
        #expect(s?.hasFailures == false)
        #expect(s?.summaryText == "5 successfull checks")
    }

    @Test func checksSummaryFromRollupNilOnNullObjectRollupEmptyOrInvalid() {
        // A branch with no pushed commit resolves `object` to null.
        #expect(GitParsing.checksSummary(fromRollupJSON: #"{"data":{"repository":{"object":null}}}"#) == nil)
        // A pushed commit with no checks resolves `statusCheckRollup` to null.
        #expect(GitParsing.checksSummary(fromRollupJSON: #"{"data":{"repository":{"object":{"statusCheckRollup":null}}}}"#) == nil)
        // A rollup with no contexts is not a zero summary.
        #expect(GitParsing.checksSummary(fromRollupJSON: #"{"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[]}}}}}}"#) == nil)
        #expect(GitParsing.checksSummary(fromRollupJSON: "") == nil)
        #expect(GitParsing.checksSummary(fromRollupJSON: "not json") == nil)
    }

    @Test func checksSummaryFromRollupIgnoresUnknownEnumValues() {
        // An unrecognized conclusion/state (or a completed run with a null
        // conclusion) is counted in no bucket, matching the bucket parser's
        // default-skip.
        let json = """
        {"data":{"repository":{"object":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":"STALE"},
          {"__typename":"CheckRun","status":"COMPLETED","conclusion":null},
          {"__typename":"StatusContext","state":"WEIRD"}
        ]}}}}}}
        """
        let s = GitParsing.checksSummary(fromRollupJSON: json)
        #expect(s?.failing == 1)   // STALE maps to failing
        #expect(s?.total == 1)     // the null conclusion and unknown state are ignored
    }

    @Test func checksSummaryTextListsNonzeroCategoriesInOrder() {
        let every = ChecksSummary(passing: 291, failing: 11, cancelled: 3, skipped: 3, pending: 2)
        #expect(every.summaryText == "11 failing, 3 cancelled, 291 successfull checks, 2 pending")
        let clean = ChecksSummary(passing: 291, failing: 0, cancelled: 0, skipped: 3, pending: 0)
        #expect(clean.summaryText == "291 successfull checks")
    }

    @Test func checksSummaryTextOmitsSkipped() {
        // Nothing is left to name when every check was skipped, and the card
        // guards its checks line on `checks != nil` rather than on the text, so
        // the line renders empty instead of being hidden.
        let skippedOnly = ChecksSummary(passing: 0, failing: 0, cancelled: 0, skipped: 3, pending: 0)
        #expect(skippedOnly.summaryText == "")
    }

    @Test func checksSummaryStatusReflectsFailuresPendingAndSuccess() {
        let failed = ChecksSummary(passing: 1, failing: 1, cancelled: 0, skipped: 0, pending: 0)
        #expect(failed.status == .failed)
        let passed = ChecksSummary(passing: 4, failing: 0, cancelled: 0, skipped: 0, pending: 0)
        #expect(passed.status == .passed)
        let running = ChecksSummary(passing: 2, failing: 0, cancelled: 0, skipped: 0, pending: 2)
        #expect(running.status == .running)
    }

    @Test func checksSummaryStatusFailuresBeatPending() {
        let failingWhilePending = ChecksSummary(passing: 1, failing: 1, cancelled: 0, skipped: 0, pending: 3)
        #expect(failingWhilePending.status == .failed)
        let cancelledWhilePending = ChecksSummary(passing: 1, failing: 0, cancelled: 1, skipped: 0, pending: 3)
        #expect(cancelledWhilePending.status == .failed)
    }
}
