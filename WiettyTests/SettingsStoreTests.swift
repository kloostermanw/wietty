import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct CheckIntervalsStoreTests {
    @Test func defaultsWhenUnset() {
        let store = ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, service: FakeTerminalService())
        #expect(store.checkIntervals == .default)
    }

    @Test func persistsAndClampsAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.checkIntervals = CheckIntervals(fast: 1, normal: 90, slow: 999_999) // fast/slow out of range
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.checkIntervals.fast == CheckIntervals.fastRange.lowerBound)
        #expect(store2.checkIntervals.normal == 90)
        #expect(store2.checkIntervals.slow == CheckIntervals.slowRange.upperBound)
    }
}
