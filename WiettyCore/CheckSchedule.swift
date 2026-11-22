import Foundation

/// Identifies one check for one workspace.
package struct ScheduleKey: Hashable {
    package let projectId: UUID
    package let kind: CheckKind

    /// Spelled out because the implicit memberwise one is internal and the store
    /// that schedules the checks is in the other module.
    package init(projectId: UUID, kind: CheckKind) {
        self.projectId = projectId
        self.kind = kind
    }
}

/// Tracks when each (workspace, check) last ran and computes which are due. Pure:
/// callers pass `now` and the current tier, so it is testable without a real clock.
package struct CheckSchedule {
    /// Spelled out for the same reason `ScheduleKey`'s is.
    package init() {}

    private var lastRun: [ScheduleKey: Date] = [:]

    package func isDue(_ key: ScheduleKey, tier: CheckTier, intervals: CheckIntervals, now: Date) -> Bool {
        guard let last = lastRun[key] else { return true }
        return now.timeIntervalSince(last) >= Double(intervals.seconds(for: tier))
    }

    /// Filters candidate (key, tier) pairs to those due now, preserving input order.
    package func due(candidates: [(key: ScheduleKey, tier: CheckTier)], intervals: CheckIntervals, now: Date) -> [ScheduleKey] {
        candidates.filter { isDue($0.key, tier: $0.tier, intervals: intervals, now: now) }.map(\.key)
    }

    package mutating func record(_ key: ScheduleKey, at time: Date) { lastRun[key] = time }

    /// Forces `key` due on the next evaluation (used by Instant triggers).
    package mutating func reset(_ key: ScheduleKey) { lastRun[key] = nil }

    package mutating func forget(projectId: UUID) {
        lastRun = lastRun.filter { $0.key.projectId != projectId }
    }
}
