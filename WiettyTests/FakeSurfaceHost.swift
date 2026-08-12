import AppKit
import Foundation
@testable import Wietty

/// A `TerminalSurfaceHosting` with no libghostty behind it.
///
/// Every test of `GhosttyService`, `GhosttyMonitor`, and `GhosttyStack` runs
/// against this. That is the point of the protocol: the substrate's logic is
/// testable in CI, and only rendering needs the app running.
@MainActor
final class FakeSurfaceHost: TerminalSurfaceHosting {
    private(set) var created: [String] = []
    private(set) var destroyed: [String] = []
    private(set) var commands: [String: String] = [:]
    private(set) var directories: [String: URL] = [:]
    private(set) var titles: [String: String?] = [:]

    /// Scripted answers. A missing `size` stands for a surface with no grid yet,
    /// which is a real state: a view that has not been laid out has no columns.
    var sizes: [String: TerminalSize] = [:]
    var snapshots: [String: ScreenSnapshot] = [:]
    var failNextCreate = false

    /// The `maxLines` of the last `snapshot` call per id.
    ///
    /// Recorded because the number itself is the contract, not just the rows that
    /// come back: reaching scrollback costs roughly 34 ms on the main actor against
    /// 0.14 ms for the viewport, and a caller that asks for more rows than the grid
    /// has pays it on every notch of a window drag. Without this, changing that
    /// argument to a fixed large number would pass the whole suite.
    private(set) var requestedMaxLines: [String: Int] = [:]

    private var views: [String: NSView] = [:]

    var onTitle: (@MainActor (String, String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    var onResized: (@MainActor (String, TerminalSize) -> Void)?
    var onCloseRequested: (@MainActor (String) -> Void)?

    func createSurface(id: String, command: String, directory: URL, title: String?) throws {
        if failNextCreate {
            failNextCreate = false
            throw SurfaceHostError.surfaceFailed
        }
        created.append(id)
        commands[id] = command
        directories[id] = directory
        titles[id] = title
        views[id] = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    }

    func destroySurface(id: String) {
        destroyed.append(id)
        views[id] = nil
    }

    func view(id: String) -> NSView? { views[id] }
    func size(id: String) -> TerminalSize? { sizes[id] }

    /// The scripted snapshot, trimmed to its last `maxLines` rows.
    ///
    /// The cursor row moves up with the rows that were dropped rather than being
    /// carried over unchanged. A `cursorY` left pointing at an index the trimmed
    /// snapshot no longer has is out of range for anything that paints it, and
    /// the real host cannot produce that state: it derives the cursor from the
    /// rows it returns.
    func snapshot(id: String, maxLines: Int) -> ScreenSnapshot? {
        requestedMaxLines[id] = maxLines
        guard let full = snapshots[id] else { return nil }
        guard full.rows.count > maxLines else { return full }
        let dropped = full.rows.count - maxLines
        return ScreenSnapshot(rows: Array(full.rows.suffix(maxLines)),
                              cols: full.cols,
                              cursorX: full.cursorX,
                              cursorY: max(full.cursorY - dropped, 0))
    }

    func emitTitle(_ id: String, _ title: String) { onTitle?(id, title) }
    func emitBell(_ id: String) { onBell?(id) }
    func emitNotification(_ id: String, title: String, body: String) {
        onDesktopNotification?(id, title, body)
    }
    func emitResize(_ id: String, _ size: TerminalSize) {
        sizes[id] = size
        onResized?(id, size)
    }
}
