import Foundation

/// Identifies one check for one workspace.
struct ScheduleKey: Hashable {
    let projectId: UUID
    let kind: CheckKind
}

/// Tracks when each (workspace, check) last ran and computes which are due. Pure:
/// callers pass `now` and the current tier, so it is testable without a real clock.
struct CheckSchedule {
    private var lastRun: [ScheduleKey: Date] = [:]

    func isDue(_ key: ScheduleKey, tier: CheckTier, intervals: CheckIntervals, now: Date) -> Bool {
        guard let last = lastRun[key] else { return true }
        return now.timeIntervalSince(last) >= Double(intervals.seconds(for: tier))
    }

    /// Filters candidate (key, tier) pairs to those due now, preserving input order.
    func due(candidates: [(key: ScheduleKey, tier: CheckTier)], intervals: CheckIntervals, now: Date) -> [ScheduleKey] {
        candidates.filter { isDue($0.key, tier: $0.tier, intervals: intervals, now: now) }.map(\.key)
    }

    mutating func record(_ key: ScheduleKey, at time: Date) { lastRun[key] = time }

    /// Forces `key` due on the next evaluation (used by Instant triggers).
    mutating func reset(_ key: ScheduleKey) { lastRun[key] = nil }

    mutating func forget(projectId: UUID) {
        lastRun = lastRun.filter { $0.key.projectId != projectId }
    }
}
