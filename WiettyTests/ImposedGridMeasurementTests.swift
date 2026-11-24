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
/// Four configurations run in one process, one surface each: the display's own
/// backing scale and the other one (1 or 2), each with the default window padding
/// and with a padding that is not the default. The other scale is simulated: the
/// window reports a backing scale factor that is not its screen's, which is what
/// `GhosttySurfaceView.synchronizeMetrics` reads. The display's settings are never
/// touched. The padding is written to the sandbox's `ghostty.cfg`, the overlay the
/// host loads after the user's own Ghostty config, so it decides the value.
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
    static let padding = (x: 13, y: 7)

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
        let padding: (x: Int, y: Int)?
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
        ]

        for (index, configuration) in configurations.enumerated() {
            if let padding = configuration.padding {
                try "window-padding-x = \(padding.x)\nwindow-padding-y = \(padding.y)\n"
                    .write(to: overlay, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: overlay)
            }
            // A host of its own per configuration, built after the overlay is
            // written, rather than `reloadConfig` on one host: a surface created
            // after a `reloadConfig` failed here with libghostty logging
            // "error initializing surface err=error.OutOfMemory".
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
          while [ ! -e "\(directory.path)/ask.$i" ]; do sleep 0.02; done
          stty size > "\(directory.path)/answer.$i.part"
          mv "\(directory.path)/answer.$i.part" "\(directory.path)/answer.$i"
          i=$((i+1))
        done
        """
        let scriptURL = directory.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let id = "imposed-\(number)"
        try host.createSurface(id: id, command: "/bin/sh \(scriptURL.path)", directory: directory, title: nil)
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
        let configured = configuration.padding.map { "\($0.x)x\($0.y)pt per side" } ?? "default"
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
