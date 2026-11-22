import Foundation

/// User-configurable polling durations (seconds) for the three tiers.
package struct CheckIntervals: Equatable {
    package var fast: Int
    package var normal: Int
    package var slow: Int

    /// Spelled out because the implicit memberwise one is internal and the store
    /// that reads these out of the config file is in another module.
    package init(fast: Int, normal: Int, slow: Int) {
        self.fast = fast
        self.normal = normal
        self.slow = slow
    }

    package static let `default` = CheckIntervals(fast: 15, normal: 60, slow: 300)

    // Bounds keep a user from hammering GitHub or setting an effectively-never interval.
    package static let fastRange: ClosedRange<Int> = 5...600
    package static let normalRange: ClosedRange<Int> = 10...3600
    package static let slowRange: ClosedRange<Int> = 30...86_400

    package func seconds(for tier: CheckTier) -> Int {
        switch tier {
        case .fast: return fast
        case .normal: return normal
        case .slow: return slow
        }
    }

    package func clamped() -> CheckIntervals {
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
