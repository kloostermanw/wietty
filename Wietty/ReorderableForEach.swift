import SwiftUI
import UniformTypeIdentifiers

/// A `ForEach` whose rows can be dragged to reorder them, for use inside a `Form`.
///
/// `.onMove` is the usual way to reorder a list, but it is a `List` affordance and
/// does not fire for a `ForEach` in a `Form` section, which is where the settings
/// lists live. So this drives the reorder by hand with `.onDrag`/`.onDrop`, which
/// work in any container: the row under the pointer moves the dragged row to its
/// place as the drag passes over it (`ReorderDropDelegate`), and `onMove` is called
/// with the same `(IndexSet, Int)` an `.onMove` would have used, so a caller can back
/// it with `Array.move` or the store equivalent.
struct ReorderableForEach<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let onMove: (IndexSet, Int) -> Void
    @ViewBuilder let content: (Item) -> Content

    @State private var dragging: Item.ID?

    var body: some View {
        ForEach(items) { item in
            content(item)
                // The dragged row dims so it reads as the one in flight while its
                // copy moves through the others.
                .opacity(dragging == item.id ? 0.5 : 1)
                .onDrag {
                    dragging = item.id
                    // The payload is unused (the delegate reorders from `dragging`);
                    // a non-empty provider is what lets the drag begin.
                    return NSItemProvider(object: String(describing: item.id) as NSString)
                }
                .onDrop(of: [.text],
                        delegate: ReorderDropDelegate(item: item, items: items,
                                                      dragging: $dragging, onMove: onMove))
        }
    }
}

/// Live-reorders as a dragged row passes over another: on entering a row's frame it
/// moves the dragged item to that row's index, so the list rearranges under the
/// pointer and the drop just settles it.
private struct ReorderDropDelegate<Item: Identifiable>: DropDelegate {
    let item: Item
    let items: [Item]
    @Binding var dragging: Item.ID?
    let onMove: (IndexSet, Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item.id,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to = items.firstIndex(where: { $0.id == item.id }) else { return }
        // `Array.move` inserts before `toOffset`, so a forward move targets the slot
        // after the row it passed.
        onMove(IndexSet(integer: from), to > from ? to + 1 : to)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
