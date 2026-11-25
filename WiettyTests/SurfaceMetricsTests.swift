import Foundation
import Testing
import WiettyCore

/// The arithmetic between a grid and the size of the view that shows it.
///
/// The table is the imposed grid measurement's (task 0 of phase 3 part 2a, every
/// `swept` line): for each configuration the cell size and the true padding it
/// measured, and for each grid the view size in points at which a real surface and
/// the `stty size` of its child both showed exactly that grid. The lines one point
/// smaller all lost a column and a row, and the lines one point larger all kept the
/// grid, which is what the boundary tests below assert of the inverse.
@Suite struct SurfaceMetricsTests {
    struct Configuration: CustomTestStringConvertible {
        let label: String
        let metrics: SurfaceMetrics
        /// Grid, and the view size in points that showed exactly it.
        let rows: [(grid: TerminalSize, width: Double, height: Double)]
        var testDescription: String { label }
    }

    private static func grid(_ cols: Int, _ rows: Int) -> TerminalSize {
        TerminalSize(cols: cols, rows: rows)
    }

    /// The measured sizes at the default padding (2 points per side). Scale 1 and
    /// scale 2 came out the same in points, as the cell and the padding both double.
    private static let defaultPadding: [(TerminalSize, Double, Double)] = [
        (grid(80, 24), 644, 412), (grid(120, 34), 964, 582), (grid(132, 43), 1060, 735),
        (grid(200, 60), 1604, 1024), (grid(40, 10), 324, 174), (grid(97, 31), 780, 531),
        (grid(300, 90), 2404, 1534),
    ]

    /// The same with `window-padding-x = 13`, `window-padding-y = 7`.
    private static let wideXPadding: [(TerminalSize, Double, Double)] = [
        (grid(80, 24), 666, 422), (grid(120, 34), 986, 592), (grid(132, 43), 1082, 745),
        (grid(200, 60), 1626, 1034), (grid(40, 10), 346, 184), (grid(97, 31), 802, 541),
        (grid(300, 90), 2426, 1544),
    ]

    static let measured: [Configuration] = [
        Configuration(label: "native/default",
                      metrics: SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 4, paddingY: 4, scale: 1),
                      rows: defaultPadding.map { ($0.0, $0.1, $0.2) }),
        Configuration(label: "simulated/default",
                      metrics: SurfaceMetrics(cellWidth: 16, cellHeight: 34, paddingX: 8, paddingY: 8, scale: 2),
                      rows: defaultPadding.map { ($0.0, $0.1, $0.2) }),
        Configuration(label: "native/padded",
                      metrics: SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 26, paddingY: 14, scale: 1),
                      rows: wideXPadding.map { ($0.0, $0.1, $0.2) }),
        Configuration(label: "simulated/padded",
                      metrics: SurfaceMetrics(cellWidth: 16, cellHeight: 34, paddingX: 52, paddingY: 28, scale: 2),
                      rows: wideXPadding.map { ($0.0, $0.1, $0.2) }),
    ]

    @Test(arguments: measured)
    func theViewSizeOfAMeasuredGridIsTheSizeThatShowedIt(_ configuration: Configuration) {
        for row in configuration.rows {
            let size = configuration.metrics.viewSize(for: row.grid)
            #expect(size.width == row.width, "\(row.grid)")
            #expect(size.height == row.height, "\(row.grid)")
        }
    }

    @Test(arguments: measured)
    func theGridFittingAMeasuredSizeIsTheGridItShowed(_ configuration: Configuration) {
        for row in configuration.rows {
            #expect(configuration.metrics.grid(fitting: row.width, row.height) == row.grid)
        }
    }

    /// The measured boundary on both sides: one point smaller lost a column and a
    /// row in every case, one point larger kept the grid in every case.
    @Test(arguments: measured)
    func onePointEitherSideOfAMeasuredSizeIsWhatTheSurfaceShowed(_ configuration: Configuration) {
        for row in configuration.rows {
            #expect(configuration.metrics.grid(fitting: row.width - 1, row.height - 1)
                    == Self.grid(row.grid.cols - 1, row.grid.rows - 1))
            #expect(configuration.metrics.grid(fitting: row.width + 1, row.height + 1) == row.grid)
        }
    }

    /// Over a sweep of pane sizes, on and between device pixels: the grid that fits
    /// never needs more than the pane, and one more column or row would.
    @Test(arguments: measured)
    func theFittingGridIsTheLargestThatFits(_ configuration: Configuration) {
        let metrics = configuration.metrics
        let smallest = metrics.viewSize(for: Self.grid(1, 1))
        var width = smallest.width
        while width < 2600 {
            let grid = metrics.grid(fitting: width, 700)
            #expect(metrics.viewSize(for: grid).width <= width, "pane \(width)")
            #expect(metrics.viewSize(for: Self.grid(grid.cols + 1, grid.rows)).width > width, "pane \(width)")
            width += 0.25
        }
        var height = smallest.height
        while height < 1700 {
            let grid = metrics.grid(fitting: 1000, height)
            #expect(metrics.viewSize(for: grid).height <= height, "pane \(height)")
            #expect(metrics.viewSize(for: Self.grid(grid.cols, grid.rows + 1)).height > height, "pane \(height)")
            height += 0.25
        }
    }

    /// Every grid, not only the measured ones, survives the round trip.
    @Test(arguments: measured)
    func everyGridSurvivesTheRoundTrip(_ configuration: Configuration) {
        for cols in stride(from: 1, through: 400, by: 7) {
            for rows in stride(from: 1, through: 150, by: 5) {
                let size = configuration.metrics.viewSize(for: Self.grid(cols, rows))
                #expect(configuration.metrics.grid(fitting: size.width, size.height) == Self.grid(cols, rows))
            }
        }
    }

    /// A pane smaller than one cell still answers one cell, as libghostty does,
    /// and nonsense sizes do not trap.
    @Test func aPaneTooSmallForOneCellAnswersOneByOne() {
        let metrics = SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 26, paddingY: 14, scale: 1)
        #expect(metrics.grid(fitting: 3, 3) == Self.grid(1, 1))
        #expect(metrics.grid(fitting: 0, -5) == Self.grid(1, 1))
        #expect(metrics.grid(fitting: .infinity, .nan) == Self.grid(1, 1))
    }

    /// At scale 2 a grid can need an odd number of pixels, which is half a point.
    /// The size stays on that device pixel rather than being rounded to a point.
    @Test func anOddPixelCountIsHalfAPointAtScaleTwo() {
        let metrics = SurfaceMetrics(cellWidth: 15, cellHeight: 33, paddingX: 8, paddingY: 8, scale: 2)
        let size = metrics.viewSize(for: Self.grid(81, 25))
        #expect(size.width == 611.5)
        #expect(size.height == 416.5)
        #expect(metrics.grid(fitting: 611.5, 416.5) == Self.grid(81, 25))
        #expect(metrics.grid(fitting: 611, 416) == Self.grid(80, 24))
    }

    /// A size is never a pixel short once the surface multiplies it back by the
    /// scale and rounds down, at any scale, not only 1 and 2.
    @Test func aViewSizeIsNeverAPixelShortAtAnyScale() {
        for scale in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 1.1, 1.3, 2.2] {
            for pixels in 1...4000 {
                let metrics = SurfaceMetrics(cellWidth: 1, cellHeight: 1, paddingX: 0, paddingY: 0, scale: scale)
                let size = metrics.viewSize(for: TerminalSize(cols: pixels, rows: pixels))
                #expect((size.width * scale).rounded(.down) >= Double(pixels), "scale \(scale) pixels \(pixels)")
                // And not a whole pixel over either.
                #expect((size.width * scale).rounded(.down) < Double(pixels) + 1, "scale \(scale) pixels \(pixels)")
            }
        }
    }

    /// Any `Int` grid gives a size rather than a trap.
    @Test func anyGridGivesASizeWithoutTrapping() {
        let metrics = SurfaceMetrics(cellWidth: 16, cellHeight: 34, paddingX: 8, paddingY: 8, scale: 2)
        let huge = metrics.viewSize(for: TerminalSize(cols: .max, rows: .max))
        #expect(huge.width.isFinite && huge.width > 0)
        let negative = metrics.viewSize(for: TerminalSize(cols: .min, rows: -3))
        #expect(negative.width.isFinite && negative.width < 0)
    }

    @Test func clampingHoldsAGridToATextureSide() {
        let metrics = SurfaceMetrics(cellWidth: 8, cellHeight: 17, paddingX: 26, paddingY: 14, scale: 1)
        #expect(metrics.clamped(TerminalSize(cols: 5000, rows: 2000), maxPixels: 16_384)
                == TerminalSize(cols: (16_384 - 26) / 8, rows: (16_384 - 14) / 17))
        #expect(metrics.clamped(TerminalSize(cols: 80, rows: 24), maxPixels: 16_384)
                == TerminalSize(cols: 80, rows: 24))
        #expect(metrics.clamped(TerminalSize(cols: 0, rows: -1), maxPixels: 16_384)
                == TerminalSize(cols: 1, rows: 1))
    }
}
