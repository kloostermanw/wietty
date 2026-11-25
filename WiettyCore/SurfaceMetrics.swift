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
    /// Always on the device pixel grid: the pixel count is whole, so dividing it by
    /// the scale gives a size that converts back to the same pixels. The `ceil` is
    /// the rounding rule spelled out rather than a value that changes anything today:
    /// were the pixel count ever fractional, up is the only safe direction.
    package func viewSize(for grid: TerminalSize) -> (width: Double, height: Double) {
        (points(grid.cols * cellWidth + paddingX), points(grid.rows * cellHeight + paddingY))
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

    private func points(_ pixels: Int) -> Double {
        Double(pixels).rounded(.up) / scale
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
