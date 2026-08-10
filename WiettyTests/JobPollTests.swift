import Testing
import Foundation
@testable import Wietty

@Suite struct JobPollTests {
    @Test func pollsOnTheFastTierWhileAWorkspaceIsExpanded() {
        #expect(JobPoll.tier(anyExpanded: true) == .fast)
    }

    @Test func pollsOnTheSlowTierWhenEveryWorkspaceIsCollapsed() {
        #expect(JobPoll.tier(anyExpanded: false) == .slow)
    }

    @Test func ignoresTheCiAndAttentionOverlays() {
        // The poll is app-wide, so one workspace's state must not bump it.
        #expect(checkTier(for: .jobNames, collapsed: false, ciPending: true,
                          needsAttention: true) == .fast)
        #expect(checkTier(for: .jobNames, collapsed: true, ciPending: true,
                          needsAttention: true) == .slow)
    }

    @Test func becomesDueAgainOnlyAfterItsIntervalElapses() {
        var schedule = CheckSchedule()
        let start = Date(timeIntervalSince1970: 0)
        let intervals = CheckIntervals.default     // fast is 15s
        #expect(schedule.isDue(JobPoll.key, tier: .fast, intervals: intervals, now: start))
        schedule.record(JobPoll.key, at: start)
        #expect(!schedule.isDue(JobPoll.key, tier: .fast, intervals: intervals,
                                now: start.addingTimeInterval(5)))
        #expect(schedule.isDue(JobPoll.key, tier: .fast, intervals: intervals,
                               now: start.addingTimeInterval(15)))
    }
}
