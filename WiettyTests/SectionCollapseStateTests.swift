import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct SectionCollapseStateTests {
    @Test func persistsPerKey() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let s = SectionCollapseState(defaults: defaults)
        #expect(s.isCollapsed("local") == false)
        s.setCollapsed("local", true)
        #expect(s.isCollapsed("local") == true)
        #expect(SectionCollapseState(defaults: defaults).isCollapsed("local") == true)
    }
}
