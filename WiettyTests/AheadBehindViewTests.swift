import Testing
import SwiftUI
@testable import Wietty

/// The colour of the behind (`↓`) group, which is the whole of what
/// `AheadBehindView` decides beyond laying the counts out. A repo that is behind
/// its remote has commits to pull, so its behind count is the one number on the
/// card that asks the user to act, and it turns red to say so.
@Suite struct AheadBehindViewTests {
    private func view(behind: Int, ahead: Int = 0) -> AheadBehindView {
        AheadBehindView(label: "origin/develop", behind: behind, ahead: ahead)
    }

    @Test func beingBehindColoursTheBehindGroupRed() {
        #expect(view(behind: 5).behindColor == .red)
        #expect(view(behind: 1).behindColor == .red)
    }

    /// Level with the remote is the resting state, so the behind group stays the
    /// same secondary as the label and the ahead group rather than shouting when
    /// there is nothing to pull.
    @Test func beingLevelKeepsTheBehindGroupSecondary() {
        #expect(view(behind: 0).behindColor == .secondary)
    }

    /// The highlight follows the behind count alone. Commits to push do not need
    /// pulling, so being ahead never reddens the behind group.
    @Test func beingAheadDoesNotColourTheBehindGroup() {
        #expect(view(behind: 0, ahead: 3).behindColor == .secondary)
    }
}
