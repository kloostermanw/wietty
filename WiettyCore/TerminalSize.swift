import Foundation

/// A terminal's grid, in cells.
///
/// In the core rather than beside `TerminalSurfaceHosting`, because the surface is
/// not the only thing that has a size: `RawPTY` is resized with one and
/// `PaneStreamHub` reports one to every viewer, and neither of those needs a window.
package struct TerminalSize: Equatable, Sendable {
    package let cols: Int
    package let rows: Int

    package init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}
