import Foundation

/// How wide the sidebar is on the libghostty substrate, where the main window is
/// a sidebar plus a terminal pane rather than a sidebar alone.
///
/// The width is explicit, and that is the point. `HSplitView` handed the surplus
/// to the sidebar as the window grew, so widening the window widened the workspace
/// list and left the terminal at its minimum, and the divider jumped once a
/// terminal opened. Owning the number fixes both: the sidebar is rigid, so the
/// pane is the only flexible half and absorbs every resize, and the number is ours
/// to persist.
///
/// Pure, and separated from the view for that reason. The gesture, the hover
/// cursor and the layout need a window; this arithmetic does not, so this is where
/// the behaviour is pinned.
enum SidebarWidth {
    /// The sidebar's own floor, matching the `minWidth` its scroll view carries on
    /// all three substrates.
    static let minimum: Double = 240

    /// The terminal pane's floor. `LocalTerminalView` reads it from here rather
    /// than repeating the number, because the sidebar's ceiling and the window's
    /// minimum are both derived from it and a second literal would let them drift.
    static let paneMinimum: Double = 480

    /// The pane's vertical floor, here for the same reason as `paneMinimum`: the
    /// window's minimum height is derived from it.
    static let paneMinimumHeight: Double = 240

    /// What the divider occupies in the row. Part of the arithmetic, not decoration:
    /// the three widths have to add up to the window, so a ceiling computed without
    /// it pushes the pane exactly this far below its minimum. Measured before the
    /// fix: a sidebar dragged fully right in a 1400 point window was 920 wide and
    /// the pane's view sat at `(926, 0, 480x728)`, six points past the window's edge.
    static let dividerWidth: Double = 6

    /// The narrowest window this shape can lay out: both halves at their floor with
    /// the divider between them.
    ///
    /// Needed explicitly because `GeometryReader` reports whatever size it is
    /// offered and never its content's minimum, so the two halves' own `minWidth`s
    /// no longer reach the window the way `HSplitView`'s arranged subviews did.
    /// Without it the window had no minimum at all (measured: `contentMin` of
    /// `0.0x32.0`), and at 500 points the terminal ran 226 points off the right
    /// edge. `ContentView` applies it, and `windowMinimumHeight` with it.
    static var windowMinimumWidth: Double { minimum + dividerWidth + paneMinimum }

    /// The shortest window this shape can lay out. The sidebar scrolls, so the right
    /// column decides: the pane's own floor plus `NavBarView` and the divider under
    /// it. Leaving the bar out of this is the same arithmetic mistake `dividerWidth`
    /// exists to prevent horizontally, and it would push the pane exactly one bar
    /// below its minimum.
    static var windowMinimumHeight: Double { paneMinimumHeight + NavBarView.height + 1 }

    /// Where a first launch puts the divider.
    ///
    /// Deliberately narrower than half of the 1100 point window this substrate
    /// opens at. The old behaviour gave the sidebar 888 of 1369 points with the
    /// pane pinned to 480, which reads as lopsided, and the terminal is the half a
    /// user is looking at.
    static let `default`: Double = 320

    /// The width to actually lay out, given what is wanted and what there is room
    /// for.
    ///
    /// Applied in two places, and both are needed. During a drag, so the pane
    /// cannot be squeezed below its minimum. And on read, because a width stored on
    /// a wide display is read back in whatever window exists later, which may be
    /// narrower or on a smaller screen.
    ///
    /// The divider's width is part of the ceiling. All three of them share
    /// `totalWidth`, so `totalWidth - paneMinimum` would hand the sidebar the
    /// divider's six points as well and the pane would end up below its minimum,
    /// which it refuses, overflowing the window instead.
    ///
    /// When `totalWidth` cannot hold both minimums the lower bound wins: the
    /// sidebar keeps its floor and the window's own minimum is what stops things
    /// going further. That ordering also covers `totalWidth` of zero, which is a
    /// real state for one layout pass before the window has been measured, and
    /// which a naive `min(desired, totalWidth - paneMinimum)` would answer with a
    /// negative width.
    static func clamped(desired: Double, totalWidth: Double) -> Double {
        let ceiling = totalWidth - paneMinimum - dividerWidth
        guard ceiling > minimum else { return minimum }
        return min(max(desired, minimum), ceiling)
    }

    /// Where a drag lands. Separated from the gesture so the arithmetic is testable
    /// without a window, and so the clamp cannot be forgotten at the one call site
    /// that matters.
    static func dragged(from start: Double, by translation: Double,
                        totalWidth: Double) -> Double {
        clamped(desired: start + translation, totalWidth: totalWidth)
    }
}
