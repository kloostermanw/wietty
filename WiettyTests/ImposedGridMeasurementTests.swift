import AppKit
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Whether a grid can be imposed on a libghostty surface by giving its view exactly
/// the size that belongs to the grid.
///
/// A measurement, not a regression test. The own pane will show a grid that another
/// viewer chose, and the design does that by sizing the surface's view to
/// `(cols * cell_width_px + padding_x) / scale` by
/// `(rows * cell_height_px + padding_y) / scale` points. Whether that comes out as
/// exactly the grid asked for, and what `padding` has to mean for it to, is what
/// this prints, one `IMPOSED` line per grid and variant.
///
/// Five configurations run in one process, one surface each: the display's own
/// backing scale and the other one (1 or 2), each with the default window padding
/// and with a padding that is not the default, and the display's scale once more
/// with a padding given as two values per axis and `window-padding-balance` on. The
/// other scale is simulated: the window reports a backing scale factor that is not
/// its screen's, which is what `GhosttySurfaceView.synchronizeMetrics` reads. The
/// display's settings are never touched. The padding is written to the sandbox's
/// `ghostty.cfg`, the overlay the host loads after the user's own Ghostty config, so
/// it decides the value.
///
/// Each grid is set twice. First by hand, on the bare view, with the padding read
/// four ways (`remainder`, `swept` and one point either side of it), which is the
/// measurement the formula came from. Then through the API the pane uses (`api`):
/// the view in a `SurfaceContainerView` as the pane holds it, the grid imposed with
/// `impose(grid:on:)` and sized from `metrics(id:)`, whose padding comes from the
/// configuration files rather than from the sweep. Then, through the same API, the
/// paths that need a real surface (`IMPOSED-EXTRA` lines, not counted): a grid
/// imposed while the view is off screen, read while it still is and again once it is
/// shown, a move to the
/// other scale and back with a grid imposed, a reload that changes the padding (last
/// configuration), and a program setting and resetting the background (first
/// configuration), which the margin follows.
///
/// **This does not run in the normal suite, by design.** It needs a window and a
/// Metal device. It runs only when `WIETTY_IMPOSED_GRID_CHECK=1` is in the
/// environment, and the supported way to run it is `scripts/imposed-grid-check.sh`.
/// Like the coexistence check, it builds a `GhosttySurfaceHost` of its own beside
/// the one the hosting app built, which takes the host callbacks over for the run.
@MainActor
@Suite(.enabled(if: ImposedGridCheck.isRequested)) struct ImposedGridMeasurementTests {
    static let grids: [TerminalSize] = [(80, 24), (120, 34), (132, 43), (200, 60), (40, 10), (97, 31), (300, 90)]
        .map { TerminalSize(cols: $0.0, rows: $0.1) }

    /// A non default padding, in points per side. Odd and unequal on purpose, so a
    /// formula that confuses the two axes, or a side with the total, shows.
    static let padding = "window-padding-x = 13\nwindow-padding-y = 7\n"

    /// Two values per axis (left and right, top and bottom), with balancing on,
    /// which hands the leftover pixels to the padding after the grid is derived.
    static let twoSidedPadding = "window-padding-x = 5,9\nwindow-padding-y = 3,8\nwindow-padding-balance = true\n"

    typealias Metrics = (columns: Int, rows: Int, widthPx: Int, heightPx: Int, cellWidthPx: Int, cellHeightPx: Int)

    /// A window that reports a backing scale of the test's choosing, which is the
    /// one way to put a surface at a scale the attached display does not have
    /// without changing the display.
    private final class ScaledWindow: NSWindow {
        var forcedScale: CGFloat?
        override var backingScaleFactor: CGFloat { forcedScale ?? super.backingScaleFactor }
    }

    private struct Configuration {
        let label: String
        let forcedScale: CGFloat?
        /// What the overlay holds, or nil for no overlay at all.
        let padding: String?
    }

    @Test func aViewSizedForAGridShowsThatGrid() async throws {
        let overlay = GhosttyOverrideFile.defaultURL
        try FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: overlay)
        defer { try? FileManager.default.removeItem(at: overlay) }

        let native = NSScreen.main?.backingScaleFactor ?? 1
        let other: CGFloat = native == 1 ? 2 : 1
        let screens = NSScreen.screens.map { "\($0.backingScaleFactor)" }.joined(separator: ",")
        print("""
        IMPOSED-ENV: display scale \(native), simulated scale \(other), screens \(screens), \
        libghostty \(GhosttySurfaceHost.libraryVersion())
        """)

        let configurations = [
            Configuration(label: "native/default", forcedScale: nil, padding: nil),
            Configuration(label: "simulated/default", forcedScale: other, padding: nil),
            Configuration(label: "native/padded", forcedScale: nil, padding: Self.padding),
            Configuration(label: "simulated/padded", forcedScale: other, padding: Self.padding),
            Configuration(label: "native/two-sided", forcedScale: nil, padding: Self.twoSidedPadding),
        ]

        for (index, configuration) in configurations.enumerated() {
            if let padding = configuration.padding {
                try padding.write(to: overlay, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: overlay)
            }
            // A host of its own per configuration, built after the overlay is
            // written. A surface once failed here after a `reloadConfig` with
            // libghostty logging "error initializing surface err=error.OutOfMemory";
            // the cause was a display asleep, not the reload (see
            // `ReloadThenCreateSurfaceTests`).
            let host = try GhosttySurfaceHost()
            try await measure(configuration, number: index, host: host)
        }
    }

    private func measure(_ configuration: Configuration, number: Int, host: GhosttySurfaceHost) async throws {
        let directory = TestScratch.root.appendingPathComponent("wietty-imposed-\(number)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The child answers `stty size` once per request file, so what it reports is
        // the pty's window size as the surface set it, read from inside.
        let script = """
        i=0
        while :; do
          while [ ! -e "\(directory.path)/ask.$i" ]; do
            # A background colour set and reset on request (OSC 11, OSC 111).
            if [ -e "\(directory.path)/osc11" ]; then rm "\(directory.path)/osc11"; printf '\\033]11;#102030\\007'; fi
            if [ -e "\(directory.path)/osc111" ]; then rm "\(directory.path)/osc111"; printf '\\033]111\\007'; fi
            sleep 0.02
          done
          stty size > "\(directory.path)/answer.$i.part"
          mv "\(directory.path)/answer.$i.part" "\(directory.path)/answer.$i"
          i=$((i+1))
        done
        """
        let scriptURL = directory.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let id = "imposed-\(number)"
        try host.createSurface(id: id, command: "/bin/sh \(scriptURL.path)", directory: directory)
        defer { host.destroySurface(id: id) }

        let window = ScaledWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
                                  styleMask: [.titled],
                                  backing: .buffered,
                                  defer: false)
        window.forcedScale = configuration.forcedScale
        window.isReleasedWhenClosed = false
        let view = try #require(host.view(id: id))
        // No autoresizing: the view's size is the thing under test, and nothing but
        // this test may set it.
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.close() }

        let scale = window.backingScaleFactor
        let start = try await settled(id, host)
        let remainderX = start.widthPx - start.columns * start.cellWidthPx
        let remainderY = start.heightPx - start.rows * start.cellHeightPx

        // The true padding: the smallest pixel size that still holds a given number
        // of cells, less those cells. Swept one pixel at a time over more than a cell.
        let probe = TerminalSize(cols: 50, rows: 20)
        let sweptX = try await smallestPixels(holding: probe.cols, cell: start.cellWidthPx, axis: \.columns,
                                              set: { view.setFrameSize(NSSize(width: CGFloat($0) / scale, height: 700)) },
                                              id, host) - probe.cols * start.cellWidthPx
        let sweptY = try await smallestPixels(holding: probe.rows, cell: start.cellHeightPx, axis: \.rows,
                                              set: { view.setFrameSize(NSSize(width: 1000, height: CGFloat($0) / scale)) },
                                              id, host) - probe.rows * start.cellHeightPx
        let configured = configuration.padding.map {
            $0.split(separator: "\n").joined(separator: ", ")
        } ?? "default"
        print("""
        IMPOSED-METRICS \(configuration.label): scale \(scale), padding config \(configured), \
        cell \(start.cellWidthPx)x\(start.cellHeightPx)px, at 1000x700pt: grid \(start.columns)x\(start.rows) \
        size \(start.widthPx)x\(start.heightPx)px remainder \(remainderX)x\(remainderY)px, \
        swept padding \(sweptX)x\(sweptY)px
        """)

        var question = 0
        for grid in Self.grids {
            // As the brief has it: the padding is whatever the last reading leaves
            // over, read afresh before each grid.
            let before = try #require(host.pixelMetrics(id: id))
            let variants: [(String, Int, Int, CGFloat)] = [
                ("remainder", before.widthPx - before.columns * before.cellWidthPx,
                 before.heightPx - before.rows * before.cellHeightPx, 0),
                ("swept", sweptX, sweptY, 0),
                ("swept-1pt", sweptX, sweptY, -1),
                ("swept+1pt", sweptX, sweptY, 1),
            ]
            for (name, padX, padY, nudge) in variants {
                let width = CGFloat(grid.cols * start.cellWidthPx + padX) / scale + nudge
                let height = CGFloat(grid.rows * start.cellHeightPx + padY) / scale + nudge
                view.setFrameSize(NSSize(width: width, height: height))
                let after = try await settled(id, host)
                let child = try await childSize(directory, question: &question,
                                                expecting: TerminalSize(cols: after.columns, rows: after.rows))
                let surfaceExact = after.columns == grid.cols && after.rows == grid.rows
                let childExact = child == TerminalSize(cols: grid.cols, rows: grid.rows)
                print("""
                IMPOSED \(configuration.label) \(name): asked \(grid.cols)x\(grid.rows) \
                surface \(after.columns)x\(after.rows) child \(child.map { "\($0.cols)x\($0.rows)" } ?? "none") \
                \(surfaceExact && childExact ? "EXACT" : "OFF") scale \(scale) \
                cell \(after.cellWidthPx)x\(after.cellHeightPx)px padding \(padX)x\(padY)px \
                view \(width)x\(height)pt size \(after.widthPx)x\(after.heightPx)px
                """)
                if nudge == 0 {
                    #expect(surfaceExact, "\(configuration.label) \(name) \(grid.cols)x\(grid.rows): surface \(after.columns)x\(after.rows)")
                    #expect(childExact, "\(configuration.label) \(name) \(grid.cols)x\(grid.rows): child \(String(describing: child))")
                }
            }
        }

        // The same grids through the pane's own API: the view held by a container as
        // the pane holds it, the grid imposed on the host, the size the host derives
        // from its own metrics.
        let container = SurfaceContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let content = try #require(window.contentView)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        SurfaceContainer.attach(view, to: container)
        content.layoutSubtreeIfNeeded()
        _ = try await settled(id, host)
        let metrics = try #require(host.metrics(id: id))
        print("""
        IMPOSED-API \(configuration.label): metrics cell \(metrics.cellWidth)x\(metrics.cellHeight)px \
        padding \(metrics.paddingX)x\(metrics.paddingY)px scale \(metrics.scale), swept padding \(sweptX)x\(sweptY)px
        """)
        #expect(metrics.paddingX == sweptX && metrics.paddingY == sweptY,
                "\(configuration.label): metrics padding \(metrics.paddingX)x\(metrics.paddingY), swept \(sweptX)x\(sweptY)")
        #expect(metrics.cellWidth == start.cellWidthPx && metrics.cellHeight == start.cellHeightPx)
        #expect(metrics.scale == Double(scale))

        for grid in Self.grids {
            host.impose(grid: grid, on: id)
            content.layoutSubtreeIfNeeded()
            let after = try await settled(id, host)
            let child = try await childSize(directory, question: &question,
                                            expecting: TerminalSize(cols: after.columns, rows: after.rows))
            let expected = metrics.viewSize(for: grid)
            let frame = view.frame
            let surfaceExact = after.columns == grid.cols && after.rows == grid.rows
            let childExact = child == grid
            print("""
            IMPOSED \(configuration.label) api: asked \(grid.cols)x\(grid.rows) \
            surface \(after.columns)x\(after.rows) child \(child.map { "\($0.cols)x\($0.rows)" } ?? "none") \
            \(surfaceExact && childExact ? "EXACT" : "OFF") scale \(scale) \
            cell \(after.cellWidthPx)x\(after.cellHeightPx)px padding \(metrics.paddingX)x\(metrics.paddingY)px \
            view \(frame.width)x\(frame.height)pt size \(after.widthPx)x\(after.heightPx)px
            """)
            #expect(surfaceExact, "\(configuration.label) api \(grid.cols)x\(grid.rows): surface \(after.columns)x\(after.rows)")
            #expect(childExact, "\(configuration.label) api \(grid.cols)x\(grid.rows): child \(String(describing: child))")
            #expect(Double(frame.width) == expected.width && Double(frame.height) == expected.height,
                    "\(configuration.label) api \(grid.cols)x\(grid.rows): frame \(frame.size), expected \(expected)")
            #expect(frame.maxY == container.bounds.maxY && frame.minX == 0)
        }

        // Cleared, the view fills the pane again.
        host.impose(grid: nil, on: id)
        content.layoutSubtreeIfNeeded()
        #expect(view.frame == container.bounds, "\(configuration.label): cleared frame \(view.frame)")

        // The paths a pane takes that need a real surface. Not counted among the
        // `IMPOSED` lines; each prints an `IMPOSED-EXTRA` line and is asserted.
        func check(_ name: String, _ grid: TerminalSize) async throws {
            content.layoutSubtreeIfNeeded()
            let after = try await settled(id, host)
            let child = try await childSize(directory, question: &question,
                                            expecting: TerminalSize(cols: after.columns, rows: after.rows))
            let now = try #require(host.metrics(id: id))
            let expected = now.viewSize(for: grid)
            let exact = after.columns == grid.cols && after.rows == grid.rows && child == grid
            print("""
            IMPOSED-EXTRA \(configuration.label) \(name): asked \(grid.cols)x\(grid.rows) \
            surface \(after.columns)x\(after.rows) child \(child.map { "\($0.cols)x\($0.rows)" } ?? "none") \
            \(exact ? "EXACT" : "OFF") scale \(now.scale) cell \(now.cellWidth)x\(now.cellHeight)px \
            padding \(now.paddingX)x\(now.paddingY)px view \(view.frame.width)x\(view.frame.height)pt
            """)
            #expect(exact, "\(configuration.label) \(name): surface \(after.columns)x\(after.rows) child \(String(describing: child))")
            #expect(Double(view.frame.width) == expected.width && Double(view.frame.height) == expected.height,
                    "\(configuration.label) \(name): frame \(view.frame.size), expected \(expected)")
        }

        // Imposed while off screen: the surface takes the grid at once, read while
        // it is still off screen (the pty and the model are at the grid in force, so
        // the surface must be too). Then shown, with the grid unchanged.
        let offscreen = TerminalSize(cols: 97, rows: 31)
        view.removeFromSuperview()
        host.impose(grid: offscreen, on: id)
        try await check("offscreen-while-hidden", offscreen)
        #expect(view.superview == nil && view.window == nil)
        SurfaceContainer.attach(view, to: container)
        try await check("offscreen-then-shown", offscreen)

        // The window moves to the other scale with a grid imposed: the host sizes the
        // view again from the new metrics, with no new impose, and back.
        let scaled = TerminalSize(cols: 80, rows: 24)
        host.impose(grid: scaled, on: id)
        try await check("before-scale-change", scaled)
        let before = window.forcedScale
        window.forcedScale = scale == 1 ? 2 : 1
        view.viewDidChangeBackingProperties()
        try await check("after-scale-change", scaled)
        #expect(host.metrics(id: id)?.scale == Double(window.backingScaleFactor))
        window.forcedScale = before
        view.viewDidChangeBackingProperties()
        try await check("scale-restored", scaled)

        // A reload that changes the configured padding. Measured (fix round 1 of
        // task 7): libghostty does not change the padding of a surface that already
        // exists, so the configured 26x14 px is disproved by the surface's own reports
        // and the metrics keep the padding it really uses, which is what keeps the
        // imposed grid exact. Last configuration only, so the others start clean.
        if configuration.label == "native/two-sided" {
            try Self.padding.write(to: GhosttyOverrideFile.defaultURL, atomically: true, encoding: .utf8)
            host.reloadConfig()
            let reloaded = TerminalSize(cols: 120, rows: 34)
            host.impose(grid: reloaded, on: id)
            try await check("after-reload", reloaded)
            let now = try #require(host.metrics(id: id))
            print("IMPOSED-EXTRA \(configuration.label) reload: configured now 26x14px, metrics padding \(now.paddingX)x\(now.paddingY)px, swept before \(sweptX)x\(sweptY)px")
            #expect(now.paddingX == sweptX && now.paddingY == sweptY,
                    "after reload: padding \(now.paddingX)x\(now.paddingY), the surface's \(sweptX)x\(sweptY)")
        }

        // A program sets the background (OSC 11): the margin follows; a reset
        // (OSC 111) brings back the configured colour. First configuration only.
        if number == 0, let surfaceView = view as? GhosttySurfaceView {
            let configured = surfaceView.marginColor
            FileManager.default.createFile(atPath: directory.appendingPathComponent("osc11").path, contents: nil)
            let set = try await waitForMargin(surfaceView) { $0 != configured }
            FileManager.default.createFile(atPath: directory.appendingPathComponent("osc111").path, contents: nil)
            let reset = try await waitForMargin(surfaceView) { $0 == configured }
            let rgb = { (c: NSColor) -> String in
                let s = c.usingColorSpace(.sRGB) ?? c
                return String(format: "%02x%02x%02x", Int((s.redComponent * 255).rounded()),
                              Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
            }
            print("IMPOSED-EXTRA \(configuration.label) colour: configured \(rgb(configured)) after OSC 11 \(rgb(set)) after OSC 111 \(rgb(reset))")
            #expect(rgb(set) == "102030")
            #expect(rgb(reset) == rgb(configured))
            #expect(container.margin?.color == reset || container.margin == nil)
        }
    }

    /// The surface's margin colour once it satisfies `done`, or the last one seen
    /// after ten seconds.
    private func waitForMargin(_ view: GhosttySurfaceView, _ done: (NSColor) -> Bool) async throws -> NSColor {
        let deadline = Date().addingTimeInterval(10)
        while !done(view.marginColor), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return view.marginColor
    }

    // MARK: - Reading

    /// The surface's metrics once they have stopped moving for a while.
    private func settled(_ id: String, _ host: GhosttySurfaceHost) async throws -> Metrics {
        var last: Metrics?
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let current = try #require(host.pixelMetrics(id: id))
            if let last, last == current, current.columns > 0 {
                if Date().timeIntervalSince(stableSince) > 0.4 { return current }
            } else {
                last = current
                stableSince = Date()
            }
        }
        throw ImposedGridError.surfaceNeverSettled
    }

    /// The smallest pixel count along one axis at which the surface reports `cells`
    /// cells, found by walking up one pixel at a time from well below it.
    private func smallestPixels(holding cells: Int, cell: Int, axis: KeyPath<Metrics, Int>,
                                set: (Int) -> Void,
                                _ id: String, _ host: GhosttySurfaceHost) async throws -> Int {
        let from = (cells - 1) * cell
        for pixels in from...(from + 4 * cell + 200) {
            set(pixels)
            try await Task.sleep(for: .milliseconds(5))
            let metrics = try #require(host.pixelMetrics(id: id))
            if metrics[keyPath: axis] >= cells { return pixels }
        }
        throw ImposedGridError.sweepFoundNothing
    }

    /// What `stty size` says inside the child. Asked again a few times while it
    /// disagrees with the surface, because the pty is resized on libghostty's IO
    /// thread and may trail the surface by a moment.
    private func childSize(_ directory: URL, question: inout Int, expecting: TerminalSize) async throws -> TerminalSize? {
        var answer: TerminalSize?
        for _ in 0..<4 {
            let ask = directory.appendingPathComponent("ask.\(question)")
            let reply = directory.appendingPathComponent("answer.\(question)")
            question += 1
            FileManager.default.createFile(atPath: ask.path, contents: nil)
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: reply.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let text = (try? String(contentsOf: reply, encoding: .utf8)) ?? ""
            let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
            answer = parts.count == 2 ? TerminalSize(cols: parts[1], rows: parts[0]) : nil
            if answer == expecting { return answer }
            try await Task.sleep(for: .milliseconds(300))
        }
        return answer
    }
}

/// Outside the suite, because a suite's own traits cannot refer to its members.
enum ImposedGridCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_IMPOSED_GRID_CHECK"] == "1"
    }
}

private enum ImposedGridError: Error {
    case surfaceNeverSettled
    case sweepFoundNothing
}
