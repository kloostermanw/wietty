import Testing
import Foundation
@testable import Wietty

/// The sidebar's width on the libghostty substrate, where the main window is a
/// sidebar plus a terminal pane rather than a sidebar alone.
///
/// The clamp is the whole of the logic, so it is the whole of what is tested. The
/// gesture, the hover cursor and the layout itself need a window and are verified
/// by hand.
@Suite struct SidebarWidthTests {
    /// The two minimums the clamp is built from, restated here so a change to
    /// either is caught rather than silently followed.
    @Test func theBoundsAreTheTwoHalvesOwnMinimums() {
        #expect(SidebarWidth.minimum == 240)
        #expect(SidebarWidth.paneMinimum == 480)
    }

    @Test func aWidthInsideTheBoundsIsKept() {
        #expect(SidebarWidth.clamped(desired: 400, totalWidth: 1400) == 400)
    }

    /// Dragging the divider left past the sidebar's own minimum must stop, not
    /// collapse the sidebar to nothing.
    @Test func draggingBelowTheSidebarMinimumStops() {
        #expect(SidebarWidth.clamped(desired: 100, totalWidth: 1400) == 240)
        #expect(SidebarWidth.clamped(desired: -50, totalWidth: 1400) == 240)
    }

    /// Dragging right must stop where the pane reaches ITS minimum, otherwise the
    /// terminal is squeezed below the width it declares it needs.
    @Test func draggingPastThePaneMinimumStops() {
        // 1400 total, 480 for the pane and 6 for the divider, so the sidebar may
        // reach 914 and no more.
        #expect(SidebarWidth.clamped(desired: 1200, totalWidth: 1400) == 914)
        #expect(SidebarWidth.clamped(desired: 914, totalWidth: 1400) == 914)
    }

    /// The divider is in the row too, and this was wrong: the ceiling ignored it,
    /// so a sidebar dragged fully right took the divider's six points as well and
    /// the pane could not have its minimum. Measured in a running window before the
    /// fix: sidebar 920, pane's view at `(926, 0, 480x728)` in a 1400 point window,
    /// six points off the right edge.
    @Test func theCeilingLeavesRoomForTheDivider() {
        #expect(SidebarWidth.dividerWidth == 6)
        for total in [726.0, 800, 1100, 1400, 3000] {
            let sidebar = SidebarWidth.clamped(desired: total, totalWidth: total)
            #expect(sidebar + SidebarWidth.dividerWidth + SidebarWidth.paneMinimum <= total)
        }
    }

    /// The window's own minimum, which `ContentView` has to restate because
    /// `GeometryReader` reports its proposal rather than its content's minimum. At
    /// exactly this width all three parts fit with nothing spare.
    @Test func theWindowMinimumIsBothHalvesPlusTheDivider() {
        #expect(SidebarWidth.windowMinimumWidth == 726)
        let total = SidebarWidth.windowMinimumWidth
        let sidebar = SidebarWidth.clamped(desired: 900, totalWidth: total)
        #expect(sidebar == SidebarWidth.minimum)
        #expect(sidebar + SidebarWidth.dividerWidth + SidebarWidth.paneMinimum == total)
    }

    /// The pane no longer owns its column alone: `NavBarView` sits above it with a
    /// divider between. A window minimum still equal to the pane's own floor would
    /// squeeze the pane below it by exactly the bar, which is the same arithmetic
    /// mistake `dividerWidth` exists to prevent horizontally.
    @Test func theWindowMinimumHeightLeavesRoomForTheBar() {
        #expect(SidebarWidth.windowMinimumHeight
                == SidebarWidth.paneMinimumHeight + NavBarView.height + 1)
    }

    /// The case that makes this a clamp rather than a range check: a width stored
    /// on a wide display, then read back in a window too narrow to honour it. The
    /// sidebar minimum wins and the window's own minimum stops it going further.
    @Test func aWindowNarrowerThanBothMinimumsFallsBackToTheSidebarMinimum() {
        // 600 total cannot hold 240 + 480, so the upper bound is below the lower.
        #expect(SidebarWidth.clamped(desired: 400, totalWidth: 600) == 240)
        #expect(SidebarWidth.clamped(desired: 100, totalWidth: 600) == 240)
    }

    /// A total width of zero happens for one layout pass before a window has been
    /// measured. It must not produce a negative or NaN width.
    @Test func anUnmeasuredWindowIsSafe() {
        #expect(SidebarWidth.clamped(desired: 320, totalWidth: 0) == 240)
    }

    /// Where a drag lands, derived rather than computed inline in the gesture, so
    /// the arithmetic is testable on its own.
    @Test func aDragOffsetsTheWidthItStartedFrom() {
        #expect(SidebarWidth.dragged(from: 320, by: 80, totalWidth: 1400) == 400)
        #expect(SidebarWidth.dragged(from: 320, by: -200, totalWidth: 1400) == 240)
        #expect(SidebarWidth.dragged(from: 900, by: 300, totalWidth: 1400) == 914)
    }

    /// A drag has to start from the width on screen rather than the one stored,
    /// because in a window too narrow to honour the stored value they differ, and
    /// starting from the stored one means the divider does not move at all until the
    /// pointer has travelled the difference.
    @Test func aDragStartsFromTheWidthOnScreenAndNotTheStoredOne() {
        let stored = 520.0
        let total = 800.0
        let onScreen = SidebarWidth.clamped(desired: stored, totalWidth: total)
        #expect(onScreen == 314)
        #expect(SidebarWidth.dragged(from: onScreen, by: -50, totalWidth: total) == 264)
        // The same drag from the stored width moves nothing, which is what the
        // divider must not do.
        #expect(SidebarWidth.dragged(from: stored, by: -50, totalWidth: total) == onScreen)
    }

    /// The default exists to stop the sidebar taking the surplus, which is what it
    /// did before: 888 points of a 1369 point window, with the pane pinned to its
    /// minimum, then jumping to an even split the moment a terminal opened.
    @Test func theDefaultIsNarrowerThanHalfATypicalWindow() {
        #expect(SidebarWidth.default == 320)
        #expect(SidebarWidth.clamped(desired: SidebarWidth.default, totalWidth: 1100) == 320)
    }
}

/// The persisted half. Follows the same shape as the port and substrate settings:
/// a stored value that survives a relaunch, a default when absent, and an
/// out of range stored value corrected rather than refused.
@MainActor
@Suite struct SidebarWidthStoreTests {
    private func defaults(_ name: String) -> UserDefaults {
        let suite = "eu.kloosterman.wietty.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Matches the local helper in `ProjectStoreChangesTests` rather than adding a
    /// shared one: the suites in this target each build their own store, and an
    /// earlier review on this branch pushed back on widening production or test
    /// surface just to seat a new suite.
    private func makeStore(defaults: UserDefaults) -> ProjectStore {
        ProjectStore(defaults: defaults,
                     service: FakeTerminalService(),
                     gitProvider: RecordingProviderStub())
    }

    @Test func absentMeansTheDefault() {
        let store = makeStore(defaults: defaults("sidebar-absent"))
        #expect(store.sidebarWidth == SidebarWidth.default)
    }

    @Test func aStoredWidthIsRead() {
        let d = defaults("sidebar-stored")
        d.set(430.0, forKey: "wietty.sidebarWidth")
        #expect(makeStore(defaults: d).sidebarWidth == 430)
    }

    @Test func aWidthSurvivesAnotherStore() {
        let d = defaults("sidebar-round-trip")
        let store = makeStore(defaults: d)
        store.sidebarWidth = 512
        #expect(makeStore(defaults: d).sidebarWidth == 512)
    }

    /// A stored width below the sidebar's own minimum is corrected on read rather
    /// than trusted, because nothing guarantees the value came from this build.
    @Test func anImpossibleStoredWidthIsCorrected() {
        let d = defaults("sidebar-impossible")
        d.set(12.0, forKey: "wietty.sidebarWidth")
        #expect(makeStore(defaults: d).sidebarWidth == SidebarWidth.minimum)
    }
}
