import AppKit
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Whether a surface can be created on a `GhosttySurfaceHost` after
/// `reloadConfig()` on that same host.
///
/// The app does exactly that: a colour change in Settings reloads the host's
/// configuration (`GhosttyColorSettings`), and the next terminal opened creates a
/// surface on it. Once, in a first version of the imposed grid measurement, the
/// first `createSurface` after a `reloadConfig()` failed with libghostty logging
/// "error initializing surface err=error.OutOfMemory", and the suspect was a use
/// after free of the configuration the reload replaces. The log of that run shows
/// otherwise: CoreVideo found no active display just before, and the pinned
/// renderer reports a display link it cannot create as `error.OutOfMemory`. This
/// runs the sequence many times, in four ways, and records every surface that
/// could not be created:
///
/// - `fresh`: a new host, one reload, one surface, the three steps as first seen.
/// - `repeat`: one host, a reload then a surface, created, shown and destroyed.
/// - `changed`: the same, with the overlay changed before every reload.
/// - `alive`: the same, with one surface kept alive through every reload, and
///   checked to still have a grid at the end.
///
/// The overlay is the sandbox's `ghostty.cfg`, never the user's own.
///
/// **This does not run in the normal suite, by design.** It needs a window and a
/// Metal device. It runs only when `WIETTY_RELOAD_SURFACE_CHECK=1` is in the
/// environment; `scripts/reload-surface-check.sh` runs it, with the address
/// sanitizer when asked. Like the other real window checks, it builds hosts of
/// its own beside the one the hosting app built.
@MainActor
@Suite(.enabled(if: ReloadSurfaceCheck.isRequested)) struct ReloadThenCreateSurfaceTests {
    static let iterations = 25

    /// Overlays the `changed` and `alive` runs cycle through: colours, a font size
    /// and a padding, so the reload rebuilds the renderer's inputs, the font grid
    /// and the surface's size.
    static let overlays = [
        "background = #102030\nforeground = #e0e0e0\n",
        "font-size = 15\n",
        "window-padding-x = 13\nwindow-padding-y = 7\n",
        "background = #302010\nfont-size = 11\n",
        "",
    ]

    @Test func aSurfaceCanBeCreatedAfterAReload() async throws {
        let overlay = GhosttyOverrideFile.defaultURL
        // The sandbox's file, never the user's own.
        #expect(!overlay.path.hasPrefix(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config").path))
        try FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: overlay)
        defer { try? FileManager.default.removeItem(at: overlay) }

        let directory = TestScratch.root.appendingPathComponent("wietty-reload-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }

        print("RELOAD-ENV: libghostty \(GhosttySurfaceHost.libraryVersion()), address sanitizer \(Self.addressSanitizerIsOn ? "ON" : "OFF")")

        var failures = 0

        // fresh: the three steps exactly, on a new host each time.
        var created = 0
        for index in 0..<Self.iterations {
            let host = try GhosttySurfaceHost()
            host.reloadConfig()
            if try await attempt(host, id: "fresh-\(index)", in: window, directory: directory) { created += 1 }
        }
        print("RELOAD fresh: \(created) of \(Self.iterations) surfaces created")
        failures += Self.iterations - created

        // repeat: one host, reload then create, no surface alive at the reload.
        let host = try GhosttySurfaceHost()
        created = 0
        for index in 0..<Self.iterations {
            host.reloadConfig()
            if try await attempt(host, id: "repeat-\(index)", in: window, directory: directory) { created += 1 }
        }
        print("RELOAD repeat: \(created) of \(Self.iterations) surfaces created")
        failures += Self.iterations - created

        // changed: the overlay changes before every reload.
        created = 0
        for index in 0..<Self.iterations {
            try Self.overlays[index % Self.overlays.count].write(to: overlay, atomically: true, encoding: .utf8)
            host.reloadConfig()
            if try await attempt(host, id: "changed-\(index)", in: window, directory: directory) { created += 1 }
        }
        print("RELOAD changed: \(created) of \(Self.iterations) surfaces created")
        failures += Self.iterations - created

        // alive: one surface lives through every reload.
        try? FileManager.default.removeItem(at: overlay)
        host.reloadConfig()
        try host.createSurface(id: "keeper", command: "/bin/sleep 600", directory: directory, title: nil)
        defer { host.destroySurface(id: "keeper") }
        let keeper = try #require(host.view(id: "keeper"))
        keeper.frame = NSRect(x: 0, y: 0, width: 400, height: 480)
        window.contentView?.addSubview(keeper)
        created = 0
        for index in 0..<Self.iterations {
            try Self.overlays[index % Self.overlays.count].write(to: overlay, atomically: true, encoding: .utf8)
            host.reloadConfig()
            if try await attempt(host, id: "alive-\(index)", in: window, directory: directory) { created += 1 }
        }
        try await Task.sleep(for: .milliseconds(200))
        let keeperGrid = host.size(id: "keeper")
        print("RELOAD alive: \(created) of \(Self.iterations) surfaces created, keeper grid \(keeperGrid.map { "\($0.cols)x\($0.rows)" } ?? "none")")
        failures += Self.iterations - created
        #expect(keeperGrid != nil)

        print("RELOAD-RESULT: \(failures) failures in \(4 * Self.iterations) creations")
        #expect(failures == 0)
    }

    /// Creates surface `id`, shows it, waits for it to report a grid, and destroys
    /// it. False when it could not be created or never reported a grid.
    private func attempt(_ host: GhosttySurfaceHost, id: String, in window: NSWindow,
                         directory: URL) async throws -> Bool {
        do {
            try host.createSurface(id: id, command: "/bin/sleep 600", directory: directory, title: nil)
        } catch {
            print("RELOAD-FAIL \(id): createSurface threw \(error)")
            return false
        }
        defer { host.destroySurface(id: id) }
        guard let view = host.view(id: id) else { return false }
        view.frame = NSRect(x: 400, y: 0, width: 400, height: 480)
        window.contentView?.addSubview(view)
        let deadline = Date().addingTimeInterval(3)
        while host.size(id: id) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // A few frames under the new configuration.
        try await Task.sleep(for: .milliseconds(60))
        guard host.size(id: id) != nil else {
            print("RELOAD-FAIL \(id): created but never reported a grid")
            return false
        }
        return true
    }

    /// Whether this process was built with the address sanitizer.
    static var addressSanitizerIsOn: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") != nil
    }
}

/// Outside the suite, because a suite's own traits cannot refer to its members.
enum ReloadSurfaceCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_RELOAD_SURFACE_CHECK"] == "1"
    }
}
