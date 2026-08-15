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

    /// What this host claims libghostty resolved, and what it would have resolved
    /// without Wietty's overlay. Settable so a test can put the two out of step,
    /// which is the state the Settings toggle has to describe rather than hide.
    var desktopNotifications: (effective: Bool, userConfig: Bool) = (true, true)
    /// How many times the setting asked for the config to be re-read. A write that
    /// does not reload leaves every open terminal on the old value, and nothing on
    /// screen would say so.
    private(set) var reloadCount = 0
    /// What `desktopNotifications` becomes on the next reload, for the case the real
    /// host has after its file was rewritten: a resolved value that changes because
    /// the config underneath it did. Nil leaves the value alone.
    var desktopNotificationsAfterReload: (effective: Bool, userConfig: Bool)?
    func reloadConfig() {
        reloadCount += 1
        if let next = desktopNotificationsAfterReload { desktopNotifications = next }
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

extension DesktopNotificationSetting {
    /// A setting over a fake host and a file under a fresh temporary directory.
    ///
    /// Every construction in the suite goes through this, for one reason that is not
    /// convenience: the real `GhosttyOverrideFile` is the developer's own
    /// `~/.config/wietty/ghostty.cfg`, and a test that built the setting with its
    /// default would read it, while one that exercised the toggle would rewrite it.
    ///
    /// - Parameter overriding: makes the host report a value that disagrees with the
    ///   user's own config, which is the state the Settings tab has to explain rather
    ///   than hide.
    @MainActor
    static func fake(overriding: Bool = false) -> DesktopNotificationSetting {
        let host = FakeSurfaceHost()
        if overriding { host.desktopNotifications = (effective: false, userConfig: true) }
        return DesktopNotificationSetting(host: host, file: .temporary())
    }
}

extension GhosttyOverrideFile {
    /// A file under a directory that does not exist yet, so a test covers the
    /// creating-it path the real first write takes.
    static func temporary() -> GhosttyOverrideFile {
        GhosttyOverrideFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/ghostty.cfg"))
    }
}
