import SwiftUI
import AppKit

/// The draggable divider between the sidebar and the terminal pane.
///
/// Exists because `HSplitView` gives no way to read or persist where its divider
/// is, and no way to say which half should absorb a window resize. See
/// `SidebarWidth` for why owning the number matters.
///
/// Deliberately thin: it holds no width of its own and decides nothing. The live
/// width belongs to `ContentView`, the persisted one to `ProjectStore`, and the
/// arithmetic and clamping to `SidebarWidth`. All this contributes is the hit
/// area, the cursor, and turning a drag into a number.
struct SidebarDivider: View {
    /// The live width, moved on every frame of a drag.
    @Binding var width: Double
    /// Where the current drag started. Held by the parent rather than here so a
    /// view rebuild mid-drag cannot lose it, and so the gesture offsets one fixed
    /// origin instead of accumulating rounding frame by frame.
    @Binding var dragStart: Double?
    /// The window's current width, for the upper clamp.
    let totalWidth: Double
    /// Called once, on release, with the width to persist. Not called during the
    /// drag: that would be one `UserDefaults` write per frame.
    let onCommit: (Double) -> Void

    /// Whether this view is the one that pushed the current cursor.
    ///
    /// `push` and `pop` are a stack, so an unmatched call of either is a leak: two
    /// pushes leave the resize cursor behind after the pointer has left, and a pop
    /// without a push takes someone else's cursor off. SwiftUI does not promise
    /// exactly one `onHover(false)` per `onHover(true)`, and this view is rebuilt on
    /// every frame of a drag, so the pairing is tracked rather than assumed.
    @State private var pushedCursor = false

    /// The visible line is one point; the grab area is wider, because a one point
    /// target is unusable with a mouse. `Divider` is not used: it inherits an
    /// inset in some containers, and this needs to run the full height.
    private static let lineWidth: Double = 1

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Self.lineWidth)
            // The same constant the clamp reserves for it, so what is laid out and
            // what the arithmetic assumes cannot drift apart.
            .frame(width: SidebarWidth.dividerWidth)
            // The grab area is transparent outside the line, so it has to be made
            // hit testable explicitly or the drag only starts on the line itself.
            .contentShape(Rectangle())
            .onHover { inside in
                // Push and pop rather than `set`: popping restores whatever the
                // cursor was, so leaving the divider does not leave the resize
                // cursor stuck over the terminal. Guarded, so the stack stays
                // balanced however many times SwiftUI reports the same state.
                if inside, !pushedCursor {
                    NSCursor.resizeLeftRight.push()
                    pushedCursor = true
                } else if !inside, pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            // A window closed while the pointer is over the divider gets no
            // `onHover(false)`, and the push would outlive the view.
            .onDisappear {
                if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // The clamped width, not the stored one. They differ when the
                        // window is too narrow to honour what was stored, and starting
                        // from the stored value there means the first few hundred
                        // points of a leftward drag move nothing, because the desire
                        // is still above the ceiling. Starting from what is on screen
                        // makes the divider follow the pointer from the first point.
                        let start = dragStart
                            ?? SidebarWidth.clamped(desired: width, totalWidth: totalWidth)
                        dragStart = start
                        width = SidebarWidth.dragged(from: start,
                                                     by: value.translation.width,
                                                     totalWidth: totalWidth)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onCommit(width)
                    }
            )
            .accessibilityLabel("Sidebar width")
            .accessibilityHint("Drag to resize the sidebar")
    }
}
