import Foundation

/// User-configurable polling durations (seconds) for the three tiers.
struct CheckIntervals: Equatable {
    var fast: Int
    var normal: Int
    var slow: Int

    static let `default` = CheckIntervals(fast: 15, normal: 60, slow: 300)

    // Bounds keep a user from hammering GitHub or setting an effectively-never interval.
    static let fastRange: ClosedRange<Int> = 5...600
    static let normalRange: ClosedRange<Int> = 10...3600
    static let slowRange: ClosedRange<Int> = 30...86_400

    func seconds(for tier: CheckTier) -> Int {
        switch tier {
        case .fast: return fast
        case .normal: return normal
        case .slow: return slow
        }
    }

    func clamped() -> CheckIntervals {
        CheckIntervals(
            fast: Self.fastRange.clamp(fast),
            normal: Self.normalRange.clamp(normal),
            slow: Self.slowRange.clamp(slow)
        )
    }
}

private extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
