import Testing
@testable import Wietty

@Suite struct TestButtonStyleTests {
    @Test func mapping() {
        #expect(testButtonAppearance(for: .idle) == TestButtonAppearance(style: .neutral, running: false))
        #expect(testButtonAppearance(for: .starting) == TestButtonAppearance(style: .neutral, running: true))
        #expect(testButtonAppearance(for: .running) == TestButtonAppearance(style: .neutral, running: true))
        #expect(testButtonAppearance(for: .stopping) == TestButtonAppearance(style: .neutral, running: true))
        #expect(testButtonAppearance(for: .finished) == TestButtonAppearance(style: .passed, running: false))
        #expect(testButtonAppearance(for: .failed(1)) == TestButtonAppearance(style: .failed, running: false))
        #expect(testButtonAppearance(for: .orphaned) == TestButtonAppearance(style: .neutral, running: false))
    }
}
