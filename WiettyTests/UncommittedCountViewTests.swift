import Testing
import SwiftUI
@testable import Wietty

/// What `UncommittedCountView` decides: a dirty tree shows its count in red, and a
/// clean tree shows nothing at all, so a tidy workspace stays quiet. Issue #81.
@Suite struct UncommittedCountViewTests {
    @Test func cleanTreeRendersNothing() {
        #expect(UncommittedCountView(count: 0).isVisible == false)
    }

    @Test func dirtyTreeRendersTheCount() {
        #expect(UncommittedCountView(count: 1).isVisible)
        #expect(UncommittedCountView(count: 10).isVisible)
    }

    @Test func countIsRed() {
        #expect(UncommittedCountView(count: 10).color == .red)
    }
}
