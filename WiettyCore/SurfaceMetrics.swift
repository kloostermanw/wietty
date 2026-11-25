import Foundation

/// What a surface reports about itself, in pixels, and its backing scale.
///
/// The arithmetic between a grid and the size of the view that shows it, which the
/// own pane needs to show a grid it did not choose (one claimed by another viewer of
/// the same terminal): the surface's view is given exactly the size that belongs to
/// that grid. Established by the imposed grid measurement
/// (`scripts/imposed-grid-check.sh`), exact for every grid measured at scale 1 and at
/// a simulated scale 2, with the default padding and with one that is not:
///
///     width_pt  = (cols * cell_width_px  + padding_x_px) / scale
///     height_pt = (rows * cell_height_px + padding_y_px) / scale
///
/// where the padding is the *configured* `window-padding-x` (and `-y`), both sides
/// together, in pixels at this scale. Not the pixels a surface happens to have left
/// over beyond its whole cells: that remainder also holds up to a cell less one pixel
/// of slack and drifts with the current size.
///
/// The lower bound is tight. A view one device pixel smaller than `viewSize(for:)`
/// loses a column (or row); anything from that size up to one cell less a pixel
/// larger keeps the grid. So a size is always rounded up to the next device pixel,
/// never down and never to nearest.
package struct SurfaceMetrics: Equatable, Sendable {
    /// One cell, in pixels at `scale`.
    package let cellWidth: Int, cellHeight: Int
    /// The configured padding in pixels at `scale`, both sides together.
    package let paddingX: Int, paddingY: Int
    /// The backing scale the surface renders at: device pixels per point.
    package let scale: Double

    package init(cellWidth: Int, cellHeight: Int, paddingX: Int, paddingY: Int, scale: Double) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.scale = scale
    }

    /// The size in points of a view that shows exactly this grid.
    ///
    /// Never a pixel short: the result times the scale, rounded down as the surface
    /// rounds its view's size (`synchronizeMetrics`), is at least the pixels the
    /// grid needs, at any scale. At scales 1 and 2 that is exactly those pixels.
    /// Safe for any `Int` input: the arithmetic is in `Double`, so a grid of
    /// nonsense size gives a huge size rather than a trap (callers clamp first;
    /// see `clamped(_:maxPixels:)`).
    package func viewSize(for grid: TerminalSize) -> (width: Double, height: Double) {
        (points(Double(grid.cols) * Double(cellWidth) + Double(paddingX)),
         points(Double(grid.rows) * Double(cellHeight) + Double(paddingY)))
    }

    /// `grid`, made no larger than what fits `maxPixels` device pixels on each
    /// side at these metrics, and at least 1 by 1.
    ///
    /// For the renderer's texture limit: a surface whose view needs more pixels
    /// than a texture can hold cannot be drawn. A grid clamped here shows fewer
    /// columns or rows than the grid asked for, which looks the same as clipping a
    /// larger view: the cells beyond the limit are not shown.
    package func clamped(_ grid: TerminalSize, maxPixels: Int) -> TerminalSize {
        func fit(_ cells: Int, cell: Int, padding: Int) -> Int {
            guard cell > 0 else { return max(1, cells) }
            return min(max(1, cells), max(1, (maxPixels - padding) / cell))
        }
        return TerminalSize(cols: fit(grid.cols, cell: cellWidth, padding: paddingX),
                            rows: fit(grid.rows, cell: cellHeight, padding: paddingY))
    }

    /// The largest grid that fits a pane of this size in points. At least 1 by 1.
    ///
    /// The inverse of `viewSize(for:)`: the result's `viewSize` does not exceed the
    /// pane, and one more column (or row) would. A pane too small for even one cell
    /// still answers 1 by 1, as libghostty does, and that grid's `viewSize` is then
    /// larger than the pane.
    package func grid(fitting width: Double, _ height: Double) -> TerminalSize {
        TerminalSize(cols: cells(in: width, cell: cellWidth, padding: paddingX),
                     rows: cells(in: height, cell: cellHeight, padding: paddingY))
    }

    /// The smallest point size that is not short of `pixels` once multiplied back
    /// by the scale and rounded down. A plain quotient can land just below the
    /// pixel boundary for some scales (1.75 does), so it is nudged up one ulp at a
    /// time until it is not; at scales 1 and 2 the quotient is exact and untouched.
    private func points(_ pixels: Double) -> Double {
        let whole = pixels.rounded(.up)
        guard scale > 0, whole.isFinite else { return whole }
        var points = whole / scale
        var nudges = 0
        while (points * scale).rounded(.down) < whole, nudges < 8 {
            points = points.nextUp
            nudges += 1
        }
        return points
    }

    /// Whole cells in `points`, counted the way the surface counts them: its pixel
    /// size is the points times the scale rounded down (`synchronizeMetrics`), less
    /// the padding, in whole cells.
    private func cells(in points: Double, cell: Int, padding: Int) -> Int {
        // Bounded so a nonsense size cannot trap in the conversion to `Int`.
        guard cell > 0, points.isFinite, points > 0 else { return 1 }
        let pixels = Int(min(points * scale, 1e9).rounded(.down))
        return max(1, (pixels - padding) / cell)
    }
}
