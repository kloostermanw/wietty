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

    @Test func checksSummaryFromCheckRunsMapsStatusAndConclusion() {
        let json = """
        {"total_count":8,"check_runs":[
          {"status":"completed","conclusion":"success"},
          {"status":"completed","conclusion":"neutral"},
          {"status":"completed","conclusion":"failure"},
          {"status":"completed","conclusion":"timed_out"},
          {"status":"completed","conclusion":"cancelled"},
          {"status":"completed","conclusion":"skipped"},
          {"status":"in_progress","conclusion":null},
          {"status":"queued","conclusion":null}
        ]}
        """
        let s = GitParsing.checksSummary(fromCheckRunsJSON: json)
        #expect(s?.passing == 2)   // success + neutral
        #expect(s?.failing == 2)   // failure + timed_out
        #expect(s?.cancelled == 1)
        #expect(s?.skipped == 1)
        #expect(s?.pending == 2)   // in_progress + queued
    }

    @Test func checksSummaryFromCheckRunsNilOnEmptyOrInvalid() {
        #expect(GitParsing.checksSummary(fromCheckRunsJSON: "") == nil)
        #expect(GitParsing.checksSummary(fromCheckRunsJSON: "not json") == nil)
        #expect(GitParsing.checksSummary(fromCheckRunsJSON: #"{"total_count":0,"check_runs":[]}"#) == nil)
    }

    @Test func checksSummaryAddingSumsFieldwise() {
        let runs = ChecksSummary(passing: 1, failing: 0, cancelled: 0, skipped: 1, pending: 0)
        let statuses = ChecksSummary(passing: 1, failing: 2, cancelled: 0, skipped: 0, pending: 1)
        let merged = runs.adding(statuses)
        #expect(merged.passing == 2)
        #expect(merged.failing == 2)
        #expect(merged.skipped == 1)
        #expect(merged.pending == 1)
        #expect(merged.total == 6)
    }

    @Test func checksSummaryFromCombinedStatusMapsStates() {
        // The legacy commit-status API (what CircleCI and other status-based
        // integrations post) has a flat `state` per context, no conclusion.
        let json = """
        {"state":"failure","total_count":5,"statuses":[
          {"context":"ci/circleci: build","state":"success"},
          {"context":"coverage","state":"pending"},
          {"context":"lint","state":"failure"},
          {"context":"deploy","state":"error"},
          {"context":"unknown","state":"weird"}
        ]}
        """
        let s = GitParsing.checksSummary(fromCombinedStatusJSON: json)
        #expect(s?.passing == 1)
        #expect(s?.pending == 1)
        #expect(s?.failing == 2)   // failure + error
        #expect(s?.total == 4)     // the unrecognized state is ignored
    }

    @Test func checksSummaryFromCombinedStatusNilOnEmptyOrInvalid() {
        #expect(GitParsing.checksSummary(fromCombinedStatusJSON: "") == nil)
        #expect(GitParsing.checksSummary(fromCombinedStatusJSON: "not json") == nil)
        #expect(GitParsing.checksSummary(fromCombinedStatusJSON: #"{"state":"pending","statuses":[]}"#) == nil)
    }

    @Test func checksSummaryFromCheckRunsIgnoresUnknownCompletedConclusion() {
        // A completed run with an unrecognized (or null) conclusion is not
        // counted in any bucket, matching the bucket parser's default-skip.
        let json = #"{"total_count":1,"check_runs":[{"status":"completed","conclusion":"stale"},{"status":"completed","conclusion":null}]}"#
        let s = GitParsing.checksSummary(fromCheckRunsJSON: json)
        #expect(s?.failing == 1)   // stale maps to failing
        #expect(s?.total == 1)     // the null-conclusion run is ignored
    }

    @Test func checksSummaryTextListsNonzeroCategories() {
        let failing = ChecksSummary(passing: 291, failing: 11, cancelled: 3, skipped: 3, pending: 0)
        #expect(failing.summaryText == "11 failing, 3 cancelled, 291 successfull checks")
        let clean = ChecksSummary(passing: 291, failing: 0, cancelled: 0, skipped: 3, pending: 0)
        #expect(clean.summaryText == "291 successfull checks")
    }

    @Test func checksSummaryTextOmitsSkipped() {
        let skippedOnly = ChecksSummary(passing: 0, failing: 0, cancelled: 0, skipped: 3, pending: 0)
        #expect(skippedOnly.summaryText == "")
        let mixed = ChecksSummary(passing: 2, failing: 0, cancelled: 0, skipped: 1, pending: 0)
        #expect(mixed.summaryText == "2 successfull checks")
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
