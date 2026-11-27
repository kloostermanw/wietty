import AppKit
import Foundation
import WiettyCore
@testable import Wietty

/// A `TerminalSurfaceHosting` with no libghostty behind it.
///
/// Every test of `GhosttyService`, `GhosttyMonitor`, and `GhosttyStack` runs
/// against this. That is the point of the protocol: the substrate's logic is
/// testable in CI, and only rendering needs the app running.
@MainActor
final class FakeSurfaceHost: TerminalSurfaceHosting, TerminalSurfaceViewing {
    private(set) var created: [String] = []
    private(set) var destroyed: [String] = []
    private(set) var directories: [String: URL] = [:]

    /// Scripted answers. A missing `size` stands for a surface with no grid yet,
    /// which is a real state: a view that has not been laid out has no columns.
    var sizes: [String: TerminalSize] = [:]
    /// Scripted the way `sizes` is. A missing entry stands for a surface whose cell
    /// size is not known yet, or one this host does not have.
    var scriptedMetrics: [String: SurfaceMetrics] = [:]
    /// Every `impose(grid:on:)`, in order, and what each surface has imposed now.
    private(set) var imposeCalls: [(grid: TerminalSize?, id: String)] = []
    private(set) var imposedGrids: [String: TerminalSize] = [:]
    var failNextCreate = false
    /// Runs inside `createSurface`, before it returns (and before a scripted failure
    /// throws), as a real host's bridge may attach to the stream while the surface is
    /// being created.
    var whileCreating: ((String) -> Void)?

    private var views: [String: NSView] = [:]

    var onTitle: (@MainActor (String, String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    var onResized: (@MainActor (String, TerminalSize) -> Void)?
    var onMetricsChanged: (@MainActor (String) -> Void)?
    var onCloseRequested: (@MainActor (String) -> Void)?
    var onInput: (@MainActor (String) -> Void)?

    func createSurface(id: String, directory: URL) throws {
        whileCreating?(id)
        if failNextCreate {
            failNextCreate = false
            throw SurfaceHostError.surfaceFailed
        }
        created.append(id)
        directories[id] = directory
        views[id] = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    }

    func destroySurface(id: String) {
        destroyed.append(id)
        views[id] = nil
    }

    func view(id: String) -> NSView? { views[id] }
    func size(id: String) -> TerminalSize? { sizes[id] }
    func metrics(id: String) -> SurfaceMetrics? { scriptedMetrics[id] }
    func impose(grid: TerminalSize?, on id: String) {
        imposeCalls.append((grid, id))
        imposedGrids[id] = grid
    }

    /// What this host claims libghostty resolved, and what it would have resolved
    /// without Wietty's overlay. Settable so a test can put the two out of step,
    /// which is the state the Settings toggle has to describe rather than hide.
    var desktopNotifications: (effective: Bool, userConfig: Bool) = (true, true)
    /// What this host claims the Ghostty configuration resolved for grapheme
    /// clustering. Settable to stand for a user who chose `legacy`.
    var graphemeClustering = true
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
    func emitInput(_ id: String) { onInput?(id) }
    func emitMetrics(_ id: String, _ metrics: SurfaceMetrics?) {
        scriptedMetrics[id] = metrics
        onMetricsChanged?(id)
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
        GhosttyOverrideFile(url: TestScratch.root
            .appendingPathComponent("\(UUID().uuidString)/ghostty.cfg"))
    }
}

/// A server socket path for a stack a test builds: `wty-<pid>-<n>.sock`, with `n` from
/// a million up so it never meets a bridge's number. The suite builds many stacks in
/// the app's one process, and `LocalSocketPaths.server()` names the process. A stack
/// stops its server (and unlinks this) when it is shut down or released; one that a
/// test leaked until the process ended is removed by the next launch's
/// `LocalSocketPaths.sweep`, which recognises the name and finds its pid gone.
func testServerSocketPath() -> String {
    TestServerSockets.lock.lock()
    TestServerSockets.last += 1
    let number = TestServerSockets.last
    TestServerSockets.lock.unlock()
    // The temp directory fits, or every socket test fails anyway.
    return (try? LocalSocketPaths.bridge(number)) ?? shortSocketPath("gst")
}

private enum TestServerSockets {
    static let lock = NSLock()
    nonisolated(unsafe) static var last = 1_000_000
}

extension GhosttyStack {
    /// A stack for a test: its local socket server on a path of its own
    /// (`testServerSocketPath()`), and terminals read at once (`readDelay` 0), since
    /// a fake host has no pane to attach. The read without a pane is logged as an
    /// error each time.
    static func testing(host: any TerminalSurfaceHosting, readDelay: TimeInterval = 0) -> GhosttyStack {
        GhosttyStack(host: host, localSocketPath: testServerSocketPath(), readDelay: readDelay)
    }
}

extension TerminalStack {
    /// The same, through the app's composition root, over an injected host and a
    /// helper path that passes the check.
    static func testing(host: any TerminalSurfaceHosting & TerminalSurfaceViewing,
                        helperPath: String? = "/usr/bin/true") -> TerminalStack {
        TerminalStack(ghosttyHost: host, helperPath: helperPath,
                      localSocketPath: testServerSocketPath(), readDelay: 0)
    }
}
