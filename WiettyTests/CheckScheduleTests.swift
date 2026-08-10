import Testing
import Foundation
@testable import Wietty

@Suite struct CheckScheduleTests {
    let pid = UUID()
    let intervals = CheckIntervals(fast: 10, normal: 20, slow: 30)
    var key: ScheduleKey { ScheduleKey(projectId: pid, kind: .gitSync) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func neverRunIsDue() {
        let s = CheckSchedule()
        #expect(s.isDue(key, tier: .slow, intervals: intervals, now: t0))
    }

    @Test func notDueBeforeIntervalDueAfter() {
        var s = CheckSchedule()
        s.record(key, at: t0)
        #expect(!s.isDue(key, tier: .normal, intervals: intervals, now: t0.addingTimeInterval(19)))
        #expect(s.isDue(key, tier: .normal, intervals: intervals, now: t0.addingTimeInterval(20)))
    }

    @Test func fasterTierBecomesDueSooner() {
        var s = CheckSchedule()
        s.record(key, at: t0)
        #expect(s.isDue(key, tier: .fast, intervals: intervals, now: t0.addingTimeInterval(10)))
        #expect(!s.isDue(key, tier: .slow, intervals: intervals, now: t0.addingTimeInterval(10)))
    }

    @Test func resetForcesDue() {
        var s = CheckSchedule()
        s.record(key, at: t0)
        s.reset(key)
        #expect(s.isDue(key, tier: .slow, intervals: intervals, now: t0.addingTimeInterval(1)))
    }

    @Test func dueFiltersCandidates() {
        var s = CheckSchedule()
        let k1 = ScheduleKey(projectId: pid, kind: .gitSync)
        let k2 = ScheduleKey(projectId: pid, kind: .ciChecks)
        s.record(k1, at: t0)          // recently run
        // k2 never run -> due
        let due = s.due(
            candidates: [(k1, .normal), (k2, .fast)],
            intervals: intervals,
            now: t0.addingTimeInterval(5)
        )
        #expect(due == [k2])
    }

    @Test func forgetDropsProjectKeys() {
        var s = CheckSchedule()
        s.record(key, at: t0)
        s.forget(projectId: pid)
        #expect(s.isDue(key, tier: .slow, intervals: intervals, now: t0.addingTimeInterval(1)))
    }
}
