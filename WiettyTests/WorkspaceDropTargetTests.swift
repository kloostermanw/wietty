import Testing
import Foundation
@testable import Wietty

/// Where the insertion indicator sits during a workspace drag. The view discards
/// this decision into an overlay's opacity, so asserting the decision is asserting
/// what the user sees before releasing.
@Suite struct WorkspaceDropTargetTests {
    private let a = UUID()
    private let b = UUID()

    /// Before anything is under the pointer, no card and not the end zone is marked,
    /// which is what leaves the sidebar undisturbed until a drag actually crosses a
    /// drop target.
    @Test func noneIndicatesNothing() {
        let target = WorkspaceDropTarget.none
        #expect(target.indicatesBefore(a) == false)
        #expect(target.indicatesEnd == false)
    }

    /// A card under the pointer marks that card and no other: the line is drawn above
    /// exactly the row the dragged card would land before.
    @Test func beforeIndicatesOnlyThatCard() {
        let target = WorkspaceDropTarget.before(a)
        #expect(target.indicatesBefore(a))
        #expect(target.indicatesBefore(b) == false)
        #expect(target.indicatesEnd == false)
    }

    /// The trailing zone marks the end and no card, so "drop at the end" is the only
    /// place the line appears while it is under the pointer.
    @Test func endIndicatesOnlyTheEnd() {
        let target = WorkspaceDropTarget.end
        #expect(target.indicatesEnd)
        #expect(target.indicatesBefore(a) == false)
    }
}
