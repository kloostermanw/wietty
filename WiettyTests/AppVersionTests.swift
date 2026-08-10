import Testing
@testable import Wietty

@Suite struct AppVersionTests {
    @Test func parsesAndStripsLeadingV() {
        #expect(AppVersion("v1.2.3") == AppVersion("1.2.3"))
        #expect(AppVersion("V2.0") == AppVersion("2.0.0"))
    }

    @Test func missingComponentsTreatedAsZero() {
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1") < AppVersion("1.0.1"))
    }

    @Test func ordersNumericallyNotLexically() {
        #expect(AppVersion("1.10.0") > AppVersion("1.9.0"))
        #expect(AppVersion("2.0.0") > AppVersion("1.99.99"))
    }

    @Test func isNewerMatchesGreaterThan() {
        #expect(AppVersion("1.1.0").isNewer(than: AppVersion("1.0.0")))
        #expect(!AppVersion("1.0.0").isNewer(than: AppVersion("1.0.0")))
        #expect(!AppVersion("1.0.0").isNewer(than: AppVersion("1.1.0")))
    }

    @Test func malformedComponentsBecomeZero() {
        #expect(AppVersion("1.x.3") == AppVersion("1.0.3"))
    }
}
