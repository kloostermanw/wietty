import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// What the pane draws, and the re-parenting it does to draw it.
///
/// The pane itself needs a Metal device and a window, so what is asserted here is
/// the part that does not: which of the three states a given launch is in, and the
/// view hierarchy surgery that switching rows performs. That surgery is the load
/// bearing property of the whole substrate, and it is testable with plain
/// `NSView`s because `SurfaceContainer` deliberately knows nothing about
/// libghostty.
@MainActor
@Suite struct LocalTerminalViewTests {
    @Test func aSelectedTerminalWithASurfaceShowsIt() {
        #expect(GhosttyPaneState.resolve(setupError: nil, session: "gt:1", hasSurface: true)
            == .terminal)
    }

    @Test func nothingSelectedIsEmpty() {
        #expect(GhosttyPaneState.resolve(setupError: nil, session: nil, hasSurface: false) == .empty)
    }

    /// A selected session whose surface is gone is the same as nothing selected.
    /// It happens for one redraw while a terminal is being closed.
    @Test func aSelectionWithNoSurfaceIsEmpty() {
        #expect(GhosttyPaneState.resolve(setupError: nil, session: "gt:1", hasSurface: false)
            == .empty)
    }

    /// The setup error wins over the selection. A stack that could not be built has
    /// no surfaces at all, so without this the user would be told "no terminal
    /// selected" about a substrate that cannot open one.
    @Test func aSetupErrorWinsOverEverything() {
        #expect(GhosttyPaneState.resolve(setupError: "no libghostty",
                                         session: "gt:1", hasSurface: true)
            == .unavailable("no libghostty"))
    }

    /// The Local header offers refreshing git status and adding a folder, and
    /// nothing else. There are no windows to arrange: every terminal is inside this
    /// app's own window.
    @Test func theLocalHeaderOffersRefreshAndAdd() {
        let buttons = ContentView.localSectionButtons(refresh: {}, add: {})
        #expect(buttons.map(\.system) == ["arrow.clockwise", "plus"])
    }

    @Test func attachingPinsTheSurfaceToItsContainer() {
        let surface = NSView()
        let container = NSView()
        SurfaceContainer.attach(surface, to: container)
        #expect(surface.superview === container)
        #expect(surface.translatesAutoresizingMaskIntoConstraints == false)
        #expect(container.constraints.count == 4)
    }

    /// Switching rows re-parents one view. This is the property the Task 1 spike
    /// established and everything since depends on: the surface is moved, never
    /// rebuilt, because rebuilding is what would lose the scrollback.
    @Test func attachingElsewhereMovesTheSurfaceRatherThanCopyingIt() {
        let surface = NSView()
        let first = NSView()
        let second = NSView()
        SurfaceContainer.attach(surface, to: first)
        SurfaceContainer.attach(surface, to: second)
        #expect(surface.superview === second)
        #expect(first.subviews.isEmpty)
        // Not eight. The constraints against the old container go with the view
        // when it leaves, and a pane switched between rows all day would otherwise
        // accumulate unsatisfiable ones.
        #expect(second.constraints.count == 4)
    }

    /// A container handed a different terminal must not end up holding two.
    @Test func attachingASecondSurfaceEvictsTheFirst() {
        let container = NSView()
        let first = NSView()
        let second = NSView()
        SurfaceContainer.attach(first, to: container)
        SurfaceContainer.attach(second, to: container)
        #expect(container.subviews.count == 1)
        #expect(container.subviews.first === second)
        #expect(first.superview == nil)
    }

    /// The one thing `dismantleNSView` must never do is take the surface with it.
    /// SwiftUI calls it whenever the pane leaves the view tree, and the terminal the
    /// user switched away from has to still be there when they switch back.
    ///
    /// Asserted as "the container lets go completely and the view is still usable",
    /// because that is what is falsifiable here: a `dismantleNSView` that freed the
    /// surface could not be written without the host losing it too, but one that left
    /// the container's constraints behind, or left the view unable to be attached
    /// again, is an easy mistake and would fail this.
    @Test func dismantlingDetachesTheSurfaceAndLeavesItUsable() {
        let surface = NSView()
        let container = NSView()
        SurfaceContainer.attach(surface, to: container)
        SurfaceContainer.dismantleNSView(container, coordinator: ())
        #expect(surface.superview == nil)
        #expect(container.subviews.isEmpty)
        // The constraints went with the view. One left behind here would be
        // unsatisfiable the moment the container is resized without it.
        #expect(container.constraints.isEmpty)
        let second = NSView()
        SurfaceContainer.attach(surface, to: second)
        #expect(surface.superview === second)
        #expect(second.constraints.count == 4)
    }

    /// The height the pane answers when it is offered a whole window.
    ///
    /// Hosted rather than inspected, because the answer is SwiftUI's and not
    /// something the view can be asked for directly. `NSHostingController` needs
    /// no window and no Metal device for the two placeholder states, and it is the
    /// same measurement the window makes of the pane when it decides how tall the
    /// row of sidebar, divider and pane has to be.
    private func heightOffered(_ pane: LocalTerminalView, window: NSSize) -> NSSize {
        NSHostingController(rootView: pane).sizeThatFits(in: window)
    }

    /// The pane must take the whole height it is offered even when it is showing a
    /// placeholder rather than a terminal.
    ///
    /// This is the fix for a real launch bug and the assertion fails without it.
    /// The window then used an `HSplitView`, which puts both halves in an
    /// `NSSplitView` whose height follows what its arranged subviews ask for, and the
    /// only thing that ever asked for the window was `SurfaceContainer`, whose
    /// `NSViewRepresentable` has no ideal size and so accepts whatever it is offered.
    /// With a placeholder in the pane the whole split view was this minimum, 240
    /// points, and an AppKit view laid out short of its superview keeps its bottom
    /// left origin, so the window's content sat in a 240 point strip at the bottom
    /// with everything above it empty. Measured in a 1369x1002 window:
    /// `NSSplitView own=(0,0 1369x240)` with no terminal open, `1369x1002` with one.
    /// The split is an `HStack` in a `GeometryReader` now, and the greed still has to
    /// be here: the pane is the half that has to fill.
    @Test func theEmptyPaneFillsTheHeightItIsOffered() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        #expect(stack.setupError == nil)
        let size = heightOffered(LocalTerminalView(stack: stack, session: nil),
                                 window: NSSize(width: 1369, height: 1002))
        #expect(size.height == 1002)
    }

    /// The same for the state a broken substrate shows. Separate because it is a
    /// different branch of the pane's `switch`, and a fix applied inside one branch
    /// rather than to the pane would pass the test above and fail this one.
    @Test func theUnavailablePaneFillsTheHeightItIsOffered() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: nil)
        #expect(stack.setupError != nil)
        let size = heightOffered(LocalTerminalView(stack: stack, session: nil),
                                 window: NSSize(width: 1369, height: 1002))
        #expect(size.height == 1002)
    }

    /// Filling the window must not cost the pane its minimum. That minimum is what
    /// the main window's own minimum size is built from, together with the sidebar's
    /// 240 points and the divider's 6, so the two constants are asserted to be the
    /// ones `SidebarWidth` hands out rather than two literals that agree today.
    ///
    /// `Double(...)` around the measured side is not noise: comparing a `CGFloat`
    /// with a `Double` inside `#expect` fails even for two values it prints as
    /// `480.0`, so the conversion is explicit.
    @Test func thePaneKeepsItsMinimumInAWindowSmallerThanIt() {
        let stack = GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        let size = heightOffered(LocalTerminalView(stack: stack, session: nil),
                                 window: NSSize(width: 100, height: 100))
        #expect(size.width == 480)
        #expect(size.height == 240)
        #expect(Double(size.width) == SidebarWidth.paneMinimum)
        #expect(Double(size.height) == SidebarWidth.paneMinimumHeight)
    }
}
