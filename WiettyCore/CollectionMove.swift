import Foundation

package extension RangeReplaceableCollection where Self: MutableCollection, Index == Int {
    /// Moves the elements at `offsets` so they sit before `destination`.
    ///
    /// SwiftUI ships exactly this on `MutableCollection`, and the store used to get
    /// it for free while it lived in the app. It cannot here: this target does not
    /// import SwiftUI, which is the point of it. The behaviour is the one a
    /// drag-to-reorder list expects and the one the store's tests already pin: the
    /// moved elements keep their relative order, and `destination` is read against
    /// the list as it was before anything moved.
    package mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moved = offsets.map { self[$0] }
        let before = offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) { remove(at: index) }
        let insertAt = index(startIndex, offsetBy: destination - before)
        insert(contentsOf: moved, at: insertAt)
    }
}
