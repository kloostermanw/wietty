import AppKit
import SwiftUI
import Testing
import WiettyCore
@testable import Wietty

/// The pane showing a grid it did not choose: the surface's view pinned to the top
/// left of its container, filling it with no imposed grid and at the imposed size
/// with one, in a margin of the terminal's background colour, clipped when larger.
///
/// Plain views in a real `NSWindow` that is never put on screen, because what is
/// asserted is Auto Layout's answer: the frames after a layout pass.
@MainActor
@Suite struct SurfaceContainerSizingTests {
    /// A surface view with no libghostty behind it, sized the way
    /// `GhosttySurfaceView` asks to be.
    final class SizedSurface: NSView, GridSizedSurface {
        var imposedSize: CGSize? {
            didSet { (superview as? SurfaceContainerView)?.surfaceSizingDidChange() }
        }
        var marginColor: NSColor = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1) {
            didSet { (superview as? SurfaceContainerView)?.surfaceSizingDidChange() }
        }
        override var acceptsFirstResponder: Bool { true }
        /// The container's size each time it said the pane changed.
        private(set) var paneSizes: [CGSize] = []
        func paneSizeDidChange() {
            paneSizes.append((superview as? SurfaceContainerView)?.bounds.size ?? .zero)
        }
    }

    /// A window that reports a backing scale of the test's choosing.
    final class ScaledWindow: NSWindow {
        var forcedScale: CGFloat?
        override var backingScaleFactor: CGFloat { forcedScale ?? super.backingScaleFactor }
    }

    private struct Pane {
        let window: ScaledWindow
        let container: SurfaceContainerView
        let surface: SizedSurface

        func layout() { window.contentView?.layoutSubtreeIfNeeded() }
    }

    /// A container filling an off screen window's content view, holding a surface.
    private func pane(width: CGFloat = 800, height: CGFloat = 600, scale: CGFloat? = nil) -> Pane {
        let window = ScaledWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.forcedScale = scale
        window.isReleasedWhenClosed = false
        let container = SurfaceContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let surface = SizedSurface()
        SurfaceContainer.attach(surface, to: container)
        let pane = Pane(window: window, container: container, surface: surface)
        pane.layout()
        return pane
    }

    /// The surface's top left corner is the container's, in the container's own
    /// (unflipped) coordinates.
    private func expectPinnedTopLeft(_ pane: Pane, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(pane.surface.frame.minX == 0, sourceLocation: sourceLocation)
        #expect(pane.surface.frame.maxY == pane.container.bounds.maxY, sourceLocation: sourceLocation)
    }

    @Test func withNoImposedGridTheSurfaceFillsThePane() {
        let pane = pane()
        defer { pane.window.close() }
        #expect(pane.surface.frame == pane.container.bounds)
        #expect(pane.container.bounds.size == NSSize(width: 800, height: 600))
    }

    /// A live resize: the width and height follow the container's in the same
    /// layout pass, as four pinned edges did, so there is never a frame of margin.
    @Test func withNoImposedGridTheSurfaceFollowsTheContainerAtOnce() {
        let pane = pane()
        defer { pane.window.close() }
        for size in [NSSize(width: 1003, height: 717), NSSize(width: 640, height: 480), NSSize(width: 1201.5, height: 800)] {
            pane.window.setContentSize(size)
            pane.layout()
            #expect(pane.surface.frame == pane.container.bounds, "\(size)")
        }
    }

    /// The surface hears of every new size of the pane (which is what the pane's own
    /// grid is computed from), once per size, also while an imposed grid keeps its own
    /// frame still, and when it is put in a container.
    @Test func theSurfaceIsToldEachNewSizeOfThePaneOnce() {
        let pane = pane()
        defer { pane.window.close() }
        #expect(pane.surface.paneSizes.last == NSSize(width: 800, height: 600))
        let told = pane.surface.paneSizes.count
        pane.layout()
        #expect(pane.surface.paneSizes.count == told)
        pane.surface.imposedSize = CGSize(width: 300, height: 200)
        pane.layout()
        for size in [NSSize(width: 1003, height: 717), NSSize(width: 640, height: 480)] {
            pane.window.setContentSize(size)
            pane.layout()
            #expect(pane.surface.paneSizes.last == size, "\(size)")
        }
        #expect(pane.surface.paneSizes.count == told + 2)
        #expect(pane.surface.frame.size == CGSize(width: 300, height: 200))
    }

    /// Top and leading pinned, width and height as their own constraints, equal to
    /// the container's with no imposed grid and constants with one.
    @Test func theConstraintsArePinnedTopLeftWithAWidthAndAHeight() {
        let pane = pane()
        defer { pane.window.close() }
        let attributes = pane.container.constraints.filter {
            $0.firstItem === pane.surface || $0.secondItem === pane.surface
        }.map(\.firstAttribute)
        #expect(Set(attributes) == [.leading, .top, .width, .height])
        #expect(pane.surface.constraints.isEmpty)

        pane.surface.imposedSize = CGSize(width: 644, height: 412)
        pane.layout()
        let own = pane.surface.constraints.filter { $0.isActive && $0.secondItem == nil }
        #expect(Set(own.map(\.firstAttribute)) == [.width, .height])
        #expect(Set(own.map(\.constant)) == [644, 412])
        let pinned = pane.container.constraints.filter {
            $0.firstItem === pane.surface || $0.secondItem === pane.surface
        }.map(\.firstAttribute)
        #expect(Set(pinned) == [.leading, .top])
    }

    /// The measured sizes from the imposed grid measurement, through `SurfaceMetrics`,
    /// come out as the surface's frame exactly: Auto Layout does not round them.
    @Test func anImposedSizeIsTheSurfacesFrameExactly() {
        let pane = pane(width: 2600, height: 1700)
        defer { pane.window.close() }
        let metrics = SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 26, paddingY: 14, scale: 1)
        for grid in [TerminalSize(cols: 80, rows: 24), TerminalSize(cols: 97, rows: 31),
                     TerminalSize(cols: 300, rows: 90)] {
            let size = metrics.viewSize(for: grid)
            pane.surface.imposedSize = CGSize(width: size.width, height: size.height)
            pane.layout()
            #expect(pane.surface.frame.size == NSSize(width: size.width, height: size.height), "\(grid)")
            expectPinnedTopLeft(pane)
        }
    }

    /// At scale 2 a grid can need half a point. The frame keeps it, so the surface
    /// gets exactly the pixels the grid needs rather than one fewer, including in a
    /// pane whose height is itself a half point.
    @Test func aHalfPointSizeSurvivesLayoutAtScaleTwo() {
        let pane = pane(width: 900, height: 700.5, scale: 2)
        defer { pane.window.close() }
        #expect(pane.window.backingScaleFactor == 2)
        let metrics = SurfaceMetrics(cellWidth: 15, cellHeight: 33, paddingX: 8, paddingY: 8, scale: 2)
        let size = metrics.viewSize(for: TerminalSize(cols: 81, rows: 25))
        pane.surface.imposedSize = CGSize(width: size.width, height: size.height)
        pane.layout()
        #expect(pane.surface.frame.size == NSSize(width: 611.5, height: 416.5))
        #expect(pane.surface.convertToBacking(pane.surface.bounds).size == NSSize(width: 1223, height: 833))
        expectPinnedTopLeft(pane)
    }

    /// A smaller grid sits top left in a margin the container draws in the
    /// terminal's background colour.
    @Test func aSmallerGridLeavesAMarginInTheBackgroundColour() throws {
        let pane = pane()
        defer { pane.window.close() }
        pane.surface.imposedSize = CGSize(width: 644, height: 412)
        pane.layout()
        #expect(pane.surface.frame == NSRect(x: 0, y: 600 - 412, width: 644, height: 412))
        let margin = try #require(pane.container.margin)
        #expect(margin.color == pane.surface.marginColor)
        // The strip to the right, full height, and the strip below the surface.
        #expect(margin.rects == [NSRect(x: 644, y: 0, width: 156, height: 600),
                                 NSRect(x: 0, y: 0, width: 644, height: 188)])
        // Nothing behind the surface: the layer itself carries no colour.
        #expect(pane.container.layer?.backgroundColor == nil)
    }

    /// With nothing imposed the container paints nothing at all, so a translucent
    /// terminal blends over the window as it did before; nor when an imposed grid
    /// covers the whole pane, or after the grid is cleared.
    @Test func thereIsNoMarginWhileTheSurfaceFillsThePane() {
        let pane = pane()
        defer { pane.window.close() }
        #expect(pane.container.margin == nil)
        #expect(pane.container.layer?.backgroundColor == nil)
        pane.surface.imposedSize = CGSize(width: 2404, height: 1534)
        pane.layout()
        #expect(pane.container.margin == nil)
        pane.surface.imposedSize = CGSize(width: 800, height: 600)
        pane.layout()
        #expect(pane.container.margin == nil)
        pane.surface.imposedSize = CGSize(width: 2404, height: 300)
        pane.layout()
        #expect(pane.container.margin?.rects == [NSRect(x: 0, y: 0, width: 800, height: 300)])
        pane.surface.imposedSize = nil
        pane.layout()
        #expect(pane.container.margin == nil)
    }

    /// The margin follows the colour: a reloaded configuration with another
    /// background repaints it.
    @Test func theMarginFollowsTheBackgroundColour() {
        let pane = pane()
        defer { pane.window.close() }
        let next = NSColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1)
        pane.surface.imposedSize = CGSize(width: 644, height: 412)
        pane.surface.marginColor = next
        pane.layout()
        #expect(pane.container.margin?.color == next)
    }

    /// A larger grid keeps its size, is cut off by the container, and nothing
    /// around it can scroll.
    @Test func aLargerGridIsClippedAndDoesNotScroll() {
        let pane = pane()
        defer { pane.window.close() }
        pane.surface.imposedSize = CGSize(width: 2404, height: 1534)
        pane.layout()
        #expect(pane.container.frame.size == NSSize(width: 800, height: 600))
        #expect(pane.surface.frame.size == NSSize(width: 2404, height: 1534))
        expectPinnedTopLeft(pane)
        #expect(pane.container.clipsToBounds)
        #expect(pane.container.layer?.masksToBounds == true)
        #expect(pane.container.enclosingScrollView == nil)
    }

    /// The same in the pane as SwiftUI hosts it: the imposed size must not make the
    /// representable ask for more room than it is given.
    @Test func aLargerGridDoesNotGrowThePaneInSwiftUI() throws {
        let surface = SizedSurface()
        let hosting = NSHostingView(rootView: SurfaceContainer(surface: surface)
            .frame(width: 800, height: 600))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let container = try #require(surface.superview as? SurfaceContainerView)
        surface.imposedSize = CGSize(width: 2404, height: 1534)
        hosting.layoutSubtreeIfNeeded()
        #expect(container.frame.size == NSSize(width: 800, height: 600))
        #expect(surface.frame.size == NSSize(width: 2404, height: 1534))
        #expect(surface.frame.maxY == container.bounds.maxY)
    }

    /// Clearing the grid returns the surface to the pane's size, in the same view
    /// and container, with nothing of the imposed size left on it.
    @Test func clearingTheGridFillsThePaneAgain() {
        let pane = pane()
        defer { pane.window.close() }
        pane.surface.imposedSize = CGSize(width: 2404, height: 1534)
        pane.layout()
        pane.surface.imposedSize = CGSize(width: 324, height: 174)
        pane.layout()
        #expect(pane.surface.frame.size == NSSize(width: 324, height: 174))
        pane.surface.imposedSize = nil
        pane.layout()
        #expect(pane.surface.superview === pane.container)
        #expect(pane.surface.frame == pane.container.bounds)
        #expect(pane.surface.constraints.isEmpty)
        #expect(pane.container.constraints.count == 4)
    }

    /// Imposing and clearing do not re-parent, so the surface keeps the first
    /// responder through both.
    @Test func imposingKeepsTheFirstResponder() {
        let pane = pane()
        defer { pane.window.close() }
        #expect(pane.window.makeFirstResponder(pane.surface))
        pane.surface.imposedSize = CGSize(width: 644, height: 412)
        pane.layout()
        #expect(pane.window.firstResponder === pane.surface)
        pane.surface.imposedSize = nil
        pane.layout()
        #expect(pane.window.firstResponder === pane.surface)
    }

    /// Nor does imposing take the first responder from something else, such as a
    /// rename field the user is typing into.
    @Test func imposingDoesNotTakeTheFirstResponder() {
        let pane = pane()
        defer { pane.window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        pane.window.contentView?.addSubview(field)
        #expect(pane.window.makeFirstResponder(field))
        let responder = pane.window.firstResponder
        pane.surface.imposedSize = CGSize(width: 644, height: 412)
        pane.layout()
        #expect(pane.window.firstResponder === responder)
        #expect(pane.window.firstResponder !== pane.surface)
    }

    /// A surface carried to another container with a grid imposed takes none of
    /// the first container's constraints along, and is sized again in its new one.
    @Test func aSurfaceMovedWithAGridImposedArrivesClean() {
        let first = pane()
        let second = pane(width: 1000, height: 700)
        defer { first.window.close(); second.window.close() }
        first.surface.imposedSize = CGSize(width: 644, height: 412)
        first.layout()
        SurfaceContainer.attach(first.surface, to: second.container)
        second.layout()
        #expect(first.container.subviews.isEmpty)
        #expect(first.container.constraints.isEmpty)
        #expect(first.surface.frame.size == NSSize(width: 644, height: 412))
        #expect(first.surface.frame.maxY == second.container.bounds.maxY)
        #expect(first.surface.constraints.filter(\.isActive).count == 2)
    }

    /// A surface that does not describe itself fills its container, and the margin
    /// is clear.
    @Test func aPlainViewFillsAndHasNoMargin() {
        let container = SurfaceContainerView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let surface = NSView()
        SurfaceContainer.attach(surface, to: container)
        container.layoutSubtreeIfNeeded()
        #expect(surface.frame == container.bounds)
        #expect(container.margin == nil)
        #expect(container.layer?.backgroundColor == nil)
    }
}

/// What the hosts answer about metrics and imposed grids, short of a real surface
/// (that is `scripts/imposed-grid-check.sh`).
@MainActor
@Suite struct SurfaceHostMetricsTests {
    @Test func theFakeHostScriptsMetricsAndRecordsImposedGrids() {
        let host = FakeSurfaceHost()
        let metrics = SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 4, paddingY: 4, scale: 1)
        #expect(host.metrics(id: "gt:1") == nil)
        host.scriptedMetrics["gt:1"] = metrics
        #expect(host.metrics(id: "gt:1") == metrics)
        #expect(host.metrics(id: "gt:unknown") == nil)

        host.impose(grid: TerminalSize(cols: 80, rows: 24), on: "gt:1")
        host.impose(grid: nil, on: "gt:1")
        #expect(host.imposeCalls.map(\.id) == ["gt:1", "gt:1"])
        #expect(host.imposeCalls.map(\.grid) == [TerminalSize(cols: 80, rows: 24), nil])
        #expect(host.imposedGrids["gt:1"] == nil)
    }

    @Test func theFakeHostReportsAMetricsChange() {
        let host = FakeSurfaceHost()
        var reported: [String] = []
        host.onMetricsChanged = { reported.append($0) }
        let metrics = SurfaceMetrics(cellWidth: 16, cellHeight: 34, paddingX: 8, paddingY: 8, scale: 2)
        host.emitMetrics("gt:1", metrics)
        #expect(reported == ["gt:1"])
        #expect(host.metrics(id: "gt:1") == metrics)
    }

    @Test func theInertHostHasNoMetrics() {
        let host = InertSurfaceHost()
        host.impose(grid: TerminalSize(cols: 80, rows: 24), on: "gt:1")
        #expect(host.metrics(id: "gt:1") == nil)
    }

    /// One report bounds the true padding to `[remainder - cell + 1, remainder]`;
    /// a configured value inside stands, one outside gives way to the upper bound.
    @Test func aConfiguredPaddingStandsOnlyInsideTheBounds() {
        var window = PaddingWindow()
        #expect(window.padding(configured: 4) == 4) // nothing observed yet
        // 124 columns of 8 in 1000 pixels leave 8: the padding is 1 to 8.
        window.observe(pixels: 1000, cells: 124, cell: 8)
        #expect(window.padding(configured: 4) == 4)
        #expect(window.padding(configured: 8) == 8)
        #expect(window.padding(configured: 0) == 8)
        #expect(window.padding(configured: 26) == 8)
    }

    /// The under estimate a single report cannot catch (configured 1, true 4,
    /// cell 8) is caught once another size narrows the bounds above it, and the
    /// value used then is never below the true padding.
    @Test func anUnderEstimateIsCaughtAsTheBoundsNarrow() {
        var window = PaddingWindow()
        window.observe(pixels: 1000, cells: 124, cell: 8) // [1, 8]
        #expect(window.padding(configured: 1) == 1)
        // 1003 px with a true padding of 4: 124 columns, remainder 11, so [4, 11].
        window.observe(pixels: 1003, cells: 124, cell: 8)
        #expect(window.lower == 4)
        #expect(window.upper == 8)
        #expect(window.padding(configured: 1) == 8)
        // And on to the exact value: 1004 px leaves 12 over 124, 1005 px 125 with 5.
        window.observe(pixels: 1005, cells: 125, cell: 8)
        #expect(window.upper == 5)
        #expect(window.padding(configured: 1) == 5)
        #expect(window.padding(configured: 4) == 4)
    }

    /// Whatever the configured value, the padding used sizes every grid so the
    /// surface shows at least that grid, and a pane's fitting grid never exceeds
    /// what the surface shows at the pane's size.
    @Test func theUpperBoundNeverClaimsTooMuch() {
        let truth = 4, cell = 8
        func surfaceCells(_ pixels: Int) -> Int { max(1, (pixels - truth) / cell) }
        for configured in [0, 1, 2, 3, 4, 5, 9, 26] {
            var window = PaddingWindow()
            for pixels in stride(from: 300, through: 1400, by: 37) {
                window.observe(pixels: pixels, cells: surfaceCells(pixels), cell: cell)
                let used = window.padding(configured: configured)
                let fitting = max(1, (pixels - used) / cell)
                #expect(fitting <= surfaceCells(pixels), "configured \(configured) at \(pixels)")
                #expect(used >= truth || used == configured, "configured \(configured) at \(pixels)")
            }
            #expect(window.padding(configured: configured) >= truth, "configured \(configured)")
        }
    }

    /// A surface of one column may have been clamped up to it, which proves
    /// nothing about the padding.
    @Test func aSingleCellSurfaceProvesNothing() {
        var window = PaddingWindow()
        window.observe(pixels: 5, cells: 1, cell: 8)
        #expect(window.padding(configured: 26) == 26)
    }

    /// The closed loop may correct an imposed size twice, and has its two again for
    /// every new grid imposed and for every new metrics key (cell size, scale,
    /// configuration), since the padding it corrected for may have moved with them.
    /// Taking the same metrics again, as each correction does, gives nothing back.
    @Test func theCorrectionBudgetIsWholeAgainForANewGridOrNewMetrics() {
        var budget = ImposedSizeCorrections()
        func take() -> Bool { budget.take() }
        budget.metricsTaken(key: [8, 17, 1, 0])
        #expect(take())
        #expect(take())
        #expect(!take())
        budget.metricsTaken(key: [8, 17, 1, 0])
        #expect(!take())

        // Another scale: a display of another backing scale.
        budget.metricsTaken(key: [8, 17, 2, 0])
        #expect(take())
        #expect(take())
        #expect(!take())
        // Another cell size, another configuration.
        budget.metricsTaken(key: [9, 18, 2, 0])
        #expect(take())
        budget.metricsTaken(key: [9, 18, 2, 1])
        #expect(take())
        #expect(take())
        #expect(!take())
        // Another grid.
        budget.gridImposed()
        #expect(take())
        #expect(take())
        #expect(!take())
    }

    /// The grid a view is sized for is held to 1 by 1, to the protocol's 10,000,
    /// and to Metal's 16384 pixel texture side at the surface's metrics.
    @Test func anImposedGridIsHeldToWhatCanBeShown() {
        let metrics = SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 4, paddingY: 4, scale: 1)
        let retina = SurfaceMetrics(cellWidth: 16, cellHeight: 34, paddingX: 8, paddingY: 8, scale: 2)
        func shown(_ cols: Int, _ rows: Int, _ m: SurfaceMetrics?) -> TerminalSize {
            GhosttySurfaceView.shownGrid(for: TerminalSize(cols: cols, rows: rows), metrics: m)
        }
        #expect(shown(80, 24, metrics) == TerminalSize(cols: 80, rows: 24))
        #expect(shown(0, -5, metrics) == TerminalSize(cols: 1, rows: 1))
        #expect(shown(.min, .min, nil) == TerminalSize(cols: 1, rows: 1))
        #expect(shown(.max, .max, nil) == TerminalSize(cols: 10_000, rows: 10_000))
        // (16384 - 4) / 8 = 2047 columns, (16384 - 4) / 17 = 963 rows.
        #expect(shown(10_000, 10_000, metrics) == TerminalSize(cols: 2047, rows: 963))
        #expect(shown(.max, 50, retina) == TerminalSize(cols: 1023, rows: 50))
        #expect(GhosttySurfaceView.maxTexturePixels == 16_384)
        let size = metrics.viewSize(for: shown(10_000, 10_000, metrics))
        #expect(size.width * 1 <= 16_384 && size.height * 1 <= 16_384)
    }

    /// A colour change action moves the margin only for the background kind.
    @Test func aBackgroundChangeIsTheMarginsColour() throws {
        let color = try #require(GhosttySurfaceHost.background(changeKind: -2, r: 0x10, g: 0x20, b: 0x30)?
            .usingColorSpace(.sRGB))
        #expect(Int((color.redComponent * 255).rounded()) == 0x10)
        #expect(Int((color.blueComponent * 255).rounded()) == 0x30)
        #expect(GhosttySurfaceHost.background(changeKind: -1, r: 1, g: 2, b: 3) == nil) // foreground
        #expect(GhosttySurfaceHost.background(changeKind: -3, r: 1, g: 2, b: 3) == nil) // cursor
    }

    /// The margin is the program's background when it set one, else the
    /// configured one, at the configured opacity.
    @Test func theMarginIsTheProgramsBackgroundAtTheConfiguredOpacity() {
        let configured = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let program = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(GhosttySurfaceView.marginColor(configured: configured, program: nil, opacity: 1) == configured)
        let set = GhosttySurfaceView.marginColor(configured: configured, program: program, opacity: 0.75)
        #expect(set.redComponent == 1)
        #expect(set.alphaComponent == 0.75)
    }

    @Test func theConfiguredBackgroundOpacityIsRead() throws {
        let url = TestScratch.root.appendingPathComponent("wietty-opacity-\(UUID().uuidString).cfg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "background-opacity = 0.75\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GhosttySurfaceHost.backgroundOpacity(loading: url) == 0.75)
        try "\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(GhosttySurfaceHost.backgroundOpacity(loading: url) == 1)
    }

    /// The margin's colour is the configuration's `background`, read through
    /// libghostty from a file alone.
    @Test func theMarginColourIsTheConfiguredBackground() throws {
        let url = TestScratch.root.appendingPathComponent("wietty-background-\(UUID().uuidString).cfg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "background = #102030\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let color = try #require(GhosttySurfaceHost.background(loading: url)?.usingColorSpace(.sRGB))
        #expect(Int((color.redComponent * 255).rounded()) == 0x10)
        #expect(Int((color.greenComponent * 255).rounded()) == 0x20)
        #expect(Int((color.blueComponent * 255).rounded()) == 0x30)
    }
}
