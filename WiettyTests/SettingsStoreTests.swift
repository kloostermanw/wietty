import Foundation
import Testing
import WiettyCore
@testable import Wietty

@MainActor
@Suite struct CheckIntervalsStoreTests {
    @Test func defaultsWhenUnset() {
        let storeFx = SettingsFixture(defaults: UserDefaults(suiteName: UUID().uuidString)!, service: FakeTerminalService())
        let store = storeFx.store
        #expect(store.checkIntervals == .default)
    }

    /// The sound this app played before the setting existed, so an upgrade is
    /// silent about itself.
    @Test func theBellSoundStartsAtTheSystemDefault() {
        let storeFx = SettingsFixture(defaults: UserDefaults(suiteName: UUID().uuidString)!, service: FakeTerminalService())
        let store = storeFx.store
        #expect(storeFx.preferences.bellSound == .systemDefault)
    }

    @Test func theBellSoundPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1Fx = SettingsFixture(defaults: defaults, service: FakeTerminalService())
        let store1 = store1Fx.store
        store1Fx.preferences.bellSound = .named("Submarine")
        let store2Fx = SettingsFixture(defaults: defaults, service: FakeTerminalService())
        let store2 = store2Fx.store
        #expect(store2Fx.preferences.bellSound == .named("Submarine"))
        store2Fx.preferences.bellSound = .silent
        #expect(SettingsFixture(defaults: defaults).preferences.bellSound == .silent)
    }

    @Test func persistsAndClampsAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1Fx = SettingsFixture(defaults: defaults, service: FakeTerminalService())
        let store1 = store1Fx.store
        store1.checkIntervals = CheckIntervals(fast: 1, normal: 90, slow: 999_999) // fast/slow out of range
        let store2Fx = SettingsFixture(defaults: defaults, service: FakeTerminalService())
        let store2 = store2Fx.store
        #expect(store2.checkIntervals.fast == CheckIntervals.fastRange.lowerBound)
        #expect(store2.checkIntervals.normal == 90)
        #expect(store2.checkIntervals.slow == CheckIntervals.slowRange.upperBound)
    }
}
