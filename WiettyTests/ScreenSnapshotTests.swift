import Testing
import Foundation
@testable import Wietty

/// The cursor approximation every libghostty snapshot carries.
///
/// libghostty's C API has no cursor getter at all, so a remote viewer's first
/// paint places the cursor itself. These are the rules that placement follows,
/// asserted here rather than only described, because the paint is built from them
/// and nothing else in the substrate can check them: the real host needs a Metal
/// device and a window, this needs neither.
@Suite struct ScreenSnapshotTests {
    /// A shell sitting at a prompt is the case this is right for: the cursor
    /// lands just after the last thing printed.
    @Test func theCursorFollowsTheLastNonEmptyRow() {
        let snapshot = ScreenSnapshot(rows: ["$ ls", "a.txt", "$ "], cols: 80)
        #expect(snapshot.cursorY == 2)
        #expect(snapshot.cursorX == 2)
    }

    /// Trailing blank rows are the usual shape of a screen, so the cursor has to
    /// skip them rather than sit at the bottom of the grid.
    @Test func trailingBlankRowsAreSkipped() {
        let snapshot = ScreenSnapshot(rows: ["$ ", "", "   ", ""], cols: 80)
        #expect(snapshot.cursorY == 0)
        #expect(snapshot.cursorX == 2)
    }

    /// A row filled to the last column would otherwise put the cursor one cell
    /// past the right edge, which a viewer draws outside its grid.
    @Test func theCursorIsClampedToTheLastColumn() {
        let snapshot = ScreenSnapshot(rows: [String(repeating: "x", count: 40)], cols: 20)
        #expect(snapshot.cursorX == 19)
    }

    /// An entirely blank screen is a real state, and it has to answer with a
    /// position inside the grid rather than with nothing.
    @Test func anEmptyScreenPutsTheCursorAtTheOrigin() {
        let blank = ScreenSnapshot(rows: ["", "", ""], cols: 80)
        #expect(blank.cursorX == 0)
        #expect(blank.cursorY == 2)
        let nothing = ScreenSnapshot(rows: [], cols: 80)
        #expect(nothing.cursorX == 0)
        #expect(nothing.cursorY == 0)
    }

    /// A zero width grid comes from a surface that has not been laid out. The
    /// clamp must not produce a negative column from it.
    @Test func aZeroWidthGridStillProducesAValidColumn() {
        let snapshot = ScreenSnapshot(rows: ["abc"], cols: 0)
        #expect(snapshot.cursorX == 0)
        #expect(snapshot.cursorY == 0)
    }

    /// The explicit initialiser is what the fake and the hub's replay use, so it
    /// must not quietly re-derive the position it was given.
    @Test func anExplicitCursorIsKept() {
        let snapshot = ScreenSnapshot(rows: ["one", "two"], cols: 80, cursorX: 7, cursorY: 0)
        #expect(snapshot.cursorX == 7)
        #expect(snapshot.cursorY == 0)
    }
}

/// The stand in every later test of this substrate runs against.
@MainActor
@Suite struct FakeSurfaceHostTests {
    /// Trimming to `maxLines` has to move the cursor row up with the rows it
    /// dropped. A `cursorY` pointing past the end of the rows it is returned with
    /// is out of range for anything that paints it, and the real host cannot
    /// produce that state because it derives the cursor from the rows it returns.
    @Test func trimmingASnapshotMovesTheCursorWithIt() throws {
        let host = FakeSurfaceHost()
        try host.createSurface(id: "gt:1", command: "/usr/bin/true",
                               directory: URL(fileURLWithPath: "/tmp"), title: nil)
        host.snapshots["gt:1"] = ScreenSnapshot(rows: ["one", "two", "three", "four"], cols: 80)
        let trimmed = try #require(host.snapshot(id: "gt:1", maxLines: 2))
        #expect(trimmed.rows == ["three", "four"])
        #expect(trimmed.cursorY == 1)
        #expect(trimmed.cursorY < trimmed.rows.count)
    }

    /// The one branch of the real host that decides what a read costs, asserted
    /// without a live surface.
    ///
    /// `GhosttyService.recordSnapshot` asks for exactly the grid's own row count, on
    /// every resize and every 300 ms while output flows, so the boundary case is not
    /// an edge here: it is the case that runs. Reading it as `>=` sent that call down
    /// the whole screen path, roughly 34 ms of main actor time per terminal per
    /// refresh instead of 0.14 ms, and nothing in the suite noticed, because
    /// `FakeSurfaceHost` answers both spans the same way.
    @Test func exactlyTheGridIsTheCheapReadAndOnlyMoreReachesScrollback() {
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 28, gridRows: 28) == false)
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 27, gridRows: 28) == false)
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 29, gridRows: 28) == true)
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 5000, gridRows: 28) == true)
    }

    /// A failure leaves no view behind, which is what `GhosttyService` relies on
    /// when it unwinds a half built terminal.
    @Test func aFailedCreateRegistersNothing() {
        let host = FakeSurfaceHost()
        host.failNextCreate = true
        #expect(throws: SurfaceHostError.surfaceFailed) {
            try host.createSurface(id: "gt:2", command: "/usr/bin/true",
                                   directory: URL(fileURLWithPath: "/tmp"), title: nil)
        }
        #expect(host.created.isEmpty)
        #expect(host.view(id: "gt:2") == nil)
    }
}
