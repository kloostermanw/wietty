import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct CheckIntervalsStoreTests {
    @Test func defaultsWhenUnset() {
        let store = ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, service: FakeTerminalService())
        #expect(store.checkIntervals == .default)
    }

    /// The sound this app played before the setting existed, so an upgrade is
    /// silent about itself.
    @Test func theBellSoundStartsAtTheSystemDefault() {
        let store = ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, service: FakeTerminalService())
        #expect(store.bellSound == .systemDefault)
    }

    @Test func theBellSoundPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.bellSound = .named("Submarine")
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.bellSound == .named("Submarine"))
        store2.bellSound = .silent
        #expect(ProjectStore(defaults: defaults, service: FakeTerminalService()).bellSound == .silent)
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
