import Testing
@testable import Wietty

@Suite struct CheckIntervalsTests {
    @Test func defaults() {
        #expect(CheckIntervals.default == CheckIntervals(fast: 15, normal: 60, slow: 300))
    }

    @Test func secondsForTier() {
        let i = CheckIntervals(fast: 10, normal: 20, slow: 30)
        #expect(i.seconds(for: .fast) == 10)
        #expect(i.seconds(for: .normal) == 20)
        #expect(i.seconds(for: .slow) == 30)
    }

    @Test func clampBelowMinAndAboveMax() {
        let low = CheckIntervals(fast: 1, normal: 1, slow: 1).clamped()
        #expect(low.fast == CheckIntervals.fastRange.lowerBound)
        #expect(low.normal == CheckIntervals.normalRange.lowerBound)
        #expect(low.slow == CheckIntervals.slowRange.lowerBound)
        let high = CheckIntervals(fast: 1_000_000, normal: 1_000_000, slow: 10_000_000).clamped()
        #expect(high.fast == CheckIntervals.fastRange.upperBound)
        #expect(high.slow == CheckIntervals.slowRange.upperBound)
    }

    @Test func clampLeavesValidValuesUntouched() {
        let ok = CheckIntervals(fast: 20, normal: 90, slow: 600)
        #expect(ok.clamped() == ok)
    }
}
