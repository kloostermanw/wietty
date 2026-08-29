import SwiftUI

/// Where the insertion indicator sits while a workspace card is being dragged over
/// the local sidebar.
///
/// The reorder logic never moves in the direction the pointer travels: both writes
/// insert at a fixed spot. `ProjectStore.move(id:before:)` always inserts before the
/// card under the pointer, so the indicator is drawn at that card's top edge, and
/// `ProjectStore.moveToEnd(id:)` always appends, so the trailing drop zone's
/// indicator sits after the last card. That is the whole of the decision, which is
/// why it is a value tested on its own rather than three booleans threaded through
/// the view.
enum WorkspaceDropTarget: Equatable {
    /// No card and not the end zone is under the pointer: nothing is drawn.
    case none
    /// The card with this id is under the pointer; the dragged card lands before it.
    case before(UUID)
    /// The trailing drop zone is under the pointer; the dragged card lands last.
    case end

    /// True when the insertion line belongs above `card`.
    func indicatesBefore(_ card: UUID) -> Bool {
        self == .before(card)
    }

    /// True when the insertion line belongs after the last card.
    var indicatesEnd: Bool {
        self == .end
    }
}

/// A thin accent line drawn at a card's top edge, or after the last card, to show
/// where a dragged workspace will land. Overlaid rather than inserted into the
/// layout so it appears and clears without shifting the cards under it.
struct WorkspaceInsertionIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 4)
            // The line sits on the card's top edge, over the drop target. Left
            // hit-testable it would steal the drag and drop on that thin strip, so it
            // is inert and only the card beneath it answers the pointer.
            .allowsHitTesting(false)
    }
}
