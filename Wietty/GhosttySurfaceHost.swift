import AppKit
import Foundation
import GhosttyKit
import WiettyCore
import os

/// The one `ghostty_app_t` and every live surface.
///
/// The only file in Wietty that imports GhosttyKit. Everything else reaches
/// libghostty through `TerminalSurfaceHosting`, so an unstable API's breaking
/// release lands here and nowhere else. The package is pinned exactly for the
/// same reason; see `project.yml`.
///
/// Everything below was established by the Task 1 spike, which drove a live
/// surface from a control socket and read the result back both as terminal state
/// and as pixels. The findings that shape this file:
///
/// - **The view supplies no layer.** libghostty replaces `view.layer` with its own
///   `IOSurfaceLayer` on the first frame. A host supplied `CAMetalLayer` is not
///   required and is actively misleading, because it survives as a detached object
///   and every scale or size write to it is silently invisible. Write metrics to
///   `view.layer`, never to a cached layer of your own.
/// - **Draw on demand, never on a clock.** Redraw only when libghostty asks, and
///   coalesce onto one main queue turn. Measured idle CPU over five seconds with a
///   live shell and no output: on demand 0.06 s, a 60 Hz `DispatchSourceTimer`
///   0.48 s, a display link 1.12 s. All three render correctly; the clocks just
///   burn that per pane, and a workspace can hold eight.
/// - **`ghostty_app_tick` runs on the main thread, in response to `wakeup_cb`,
///   and once more right after a surface is freed (`destroySurface`).** There is
///   no polling interval to choose. Every other call in this API is main thread
///   only.
/// - **A view holding a live surface survives re-parenting.** Removed from its
///   superview and added back, and moved into a brand new `NSWindow`, with the
///   shell still running and the scrollback intact. The whole pane design rests on
///   that: the surface is never recreated, because recreating it is what would
///   lose the scrollback.
@MainActor
final class GhosttySurfaceHost: TerminalSurfaceHosting, TerminalSurfaceViewing {
    /// A surface and the view libghostty renders it into. The two are created
    /// together and freed together: `ghostty_surface_new` takes the view, so a
    /// surface without one cannot exist.
    private struct Surface {
        let view: GhosttySurfaceView
        let handle: ghostty_surface_t
    }

    static let log = Logger(subsystem: "eu.kloosterman.wietty", category: "ghostty")

    /// `nonisolated(unsafe)` only so `deinit`, which Swift runs outside the main
    /// actor, can free them. Every other access is on the main actor, and the one
    /// host is owned by main actor state (`GhosttyStack`), so its deinit runs
    /// there too.
    private nonisolated(unsafe) var app: ghostty_app_t?
    private nonisolated(unsafe) var config: ghostty_config_t?
    private nonisolated(unsafe) var surfaces: [String: Surface] = [:]
    /// The configuration of a viewer surface (`buildViewerConfig`), checked to deny a
    /// program the clipboard. Nil when it could not be built so, and then no viewer
    /// surface is made, since one would take a program's clipboard requests. Replaced
    /// on a reload only by another that passed the same check.
    private nonisolated(unsafe) var viewerConfig: ghostty_config_t?

    /// The surfaces that show a terminal of another Mac (`createViewerSurface`), and
    /// the pane's grid of each that was given one.
    private var viewers: Set<String> = []
    private var viewerGrids: [String: OwnPaneGrid] = [:]
    /// Told every grid a viewer's surface reports (`observeViewerGrid`).
    private var viewerGridObservers: [String: @MainActor (TerminalSize) -> Void] = [:]

    /// The pasteboard the clipboard callbacks and a copy use: the general one, unless
    /// a test hands the host a private one.
    let pasteboard: NSPasteboard

    /// The label the app gave each surface. libghostty has no title setter of any
    /// kind, so this is the host's own record rather than something pushed into
    /// the terminal; `GHOSTTY_ACTION_SET_TITLE` overwrites it when the shell sets
    /// one.
    private var titles: [String: String] = [:]

    var onTitle: (@MainActor (String, String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    var onResized: (@MainActor (String, TerminalSize) -> Void)?
    var onMetricsChanged: (@MainActor (String) -> Void)?
    var onCloseRequested: (@MainActor (String) -> Void)?
    var onInput: (@MainActor (String) -> Void)?

    /// The window padding the configuration sets, read from its files because
    /// libghostty does not expose it (`GhosttyPadding`). Resolved again on every
    /// `reloadConfig()`, so `metrics(id:)` always carries the current value.
    fileprivate private(set) var padding = GhosttyPadding.ghosttyDefault

    /// The configuration's `background` and `background-opacity`, which the pane
    /// draws around a grid smaller than itself. Resolved again on every
    /// `reloadConfig()`.
    fileprivate private(set) var background = NSColor.black
    fileprivate private(set) var backgroundOpacity = 1.0
    /// Counts configuration loads, so a surface knows its padding bounds were
    /// gathered under another configuration.
    fileprivate private(set) var configGeneration = 0

    /// The action and wakeup callbacks are C function pointers and cannot
    /// capture, so the one host is reached through this. Weak on purpose: a
    /// callback that has already hopped to the main queue must find nothing
    /// rather than resurrect a released host. There is exactly one host per
    /// launch, created by `TerminalStack`, so this cannot be ambiguous.
    private static weak var current: GhosttySurfaceHost?

    /// How many times this process has tried to construct a host, successfully or
    /// not.
    ///
    /// Exists for one assertion, and pins the property the whole substrate rests
    /// on: nothing outside the ghostty path may initialise libghostty, read the
    /// user's Ghostty config, or allocate a Metal device. A `TerminalStack` test
    /// asserting its `ghostty` is nil cannot see a stray `GhosttySurfaceHost()` on
    /// another branch, because the stack would not be holding it. This can.
    static private(set) var initCount = 0

    /// The bridge of every surface `createSurface(id:directory:title:)` made. Nil for
    /// a host built with none, which can create a surface only for an explicit
    /// command (`createSurface(id:command:directory:title:)`).
    private let bridges: PaneBridges?

    /// - Parameter bridges: joins each surface to its terminal's stream. The app
    ///   passes one; a test that drives a surface with a command of its own does not.
    /// - Parameter pasteboard: the general pasteboard unless a test says otherwise.
    /// - Parameter drainsOnDestroy: whether `destroySurface` drains libghostty's
    ///   mailbox. Always on in the app, which never passes it; only the R8
    ///   measurement turns it off, to show what happens without it.
    init(bridges: PaneBridges? = nil, pasteboard: NSPasteboard = .general,
         drainsOnDestroy: Bool = true) throws {
        self.bridges = bridges
        self.pasteboard = pasteboard
        self.drainsOnDestroy = drainsOnDestroy
        // Counted first, so a construction that then fails still shows. What is
        // being watched is whether anything reached for libghostty at all, not
        // whether it got a working host out of it.
        Self.initCount += 1
        // argc 0 on purpose. libghostty must not read Wietty's argv, and
        // `ghostty_cli_try_action` must never be called: either makes this
        // process behave like the `ghostty` CLI instead of like Wietty.
        guard ghostty_init(0, nil) == 0 else {
            throw SurfaceHostError.initFailed("libghostty could not initialise.")
        }

        let config = Self.buildConfig()
        self.config = config
        viewerConfig = Self.buildViewerConfig()
        padding = GhosttyPadding.resolveHostConfiguration()
        background = Self.background(in: config) ?? .black
        backgroundOpacity = Self.backgroundOpacity(in: config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        // Arrives on libghostty's own IO thread and means "your event loop has
        // work". Everything it leads to is main actor only, so it hops first.
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GhosttySurfaceHost.current?.tickAndRedrawAll() }
            }
        }
        runtime.action_cb = { _, target, action in
            GhosttySurfaceHost.dispatch(target: target, action: action)
        }
        // libghostty calls into these unconditionally; a null pointer is a crash.
        runtime.read_clipboard_cb = { userdata, _, request in
            GhosttySurfaceHost.readClipboard(userdata: userdata, request: request)
        }
        runtime.confirm_read_clipboard_cb = { userdata, string, request, kind in
            GhosttySurfaceHost.confirmReadClipboard(userdata: userdata,
                                                    string: string,
                                                    request: request,
                                                    kind: ClipboardRequest(kind: Int(kind.rawValue)))
        }
        // A program's `OSC 52` write, or a copy binding of the user's own Ghostty
        // configuration; the callback is not told which, so nothing here can refuse a
        // program's write. A viewer surface's configuration is the only line: it has
        // libghostty refuse the write before this is called (`viewerOverlay`).
        runtime.write_clipboard_cb = { _, _, contents, count, _ in
            guard count > 0, let data = contents?.pointee.data else { return }
            let string = String(cString: data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let pasteboard = GhosttySurfaceHost.current?.pasteboard else { return }
                    pasteboard.clearContents()
                    pasteboard.setString(string, forType: .string)
                }
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            GhosttySurfaceHost.closeSurface(userdata: userdata)
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            self.config = nil
            if let viewerConfig { ghostty_config_free(viewerConfig) }
            viewerConfig = nil
            throw SurfaceHostError.initFailed("libghostty could not create its app.")
        }
        self.app = app
        GhosttySurfaceHost.current = self
        Self.log.info("libghostty \(Self.libraryVersion(), privacy: .public)")
    }

    /// The linked libghostty's own version string, for logs and bug reports. The
    /// pin is exact, so a mismatch between this and `project.yml` means a stale
    /// resolved package rather than a version range.
    static func libraryVersion() -> String {
        let info = ghostty_info()
        guard let pointer = info.version, info.version_len > 0 else { return "unknown" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(info.version_len)),
                      as: UTF8.self) + " (build mode \(info.build_mode.rawValue))"
    }

    // MARK: - Configuration

    /// The user's Ghostty config, then Wietty's own file over the top.
    ///
    /// Order is the whole mechanism. libghostty has no setter, so the only way to
    /// change a value is to load another file after the one that set it, and the
    /// last file to set a key wins. Loading the user's config first keeps the font,
    /// theme and cursor they already chose for Ghostty, which is why it is loaded at
    /// all; loading Wietty's file second is what makes a toggle in Wietty's Settings
    /// window mean anything.
    ///
    /// The overlay is loaded unconditionally. A path that does not exist is not an
    /// error to libghostty: it sets no values and raises no diagnostics, which is
    /// exactly what "Wietty has no opinion" should do, so there is nothing to check
    /// for first.
    ///
    /// - Parameter overlay: nil builds the user's configuration alone, which is what
    ///   `desktopNotifications` compares against to tell whether Wietty is
    ///   overriding a value the user set themselves.
    /// - Parameter viewer: `viewerOverlay`'s file, loaded last, for a viewer surface's
    ///   configuration.
    private static func buildConfig(overlay: URL? = GhosttyOverrideFile.defaultURL,
                                    viewer: URL? = nil) -> ghostty_config_t? {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        if let overlay { ghostty_config_load_file(config, overlay.path) }
        if let viewer { ghostty_config_load_file(config, viewer.path) }
        ghostty_config_finalize(config)
        return config
    }

    /// What a viewer surface's configuration adds over the app's: libghostty refuses a
    /// program's `OSC 52` read and write on it (logging "application attempted to read
    /// clipboard, but 'clipboard-read' is set to deny"), so a program on another Mac can
    /// neither read nor set this Mac's clipboard. Neither key governs the user's own
    /// paste or copy. Last, so it wins over the user's Ghostty config and Wietty's file.
    ///
    /// Done by configuration because the clipboard callbacks cannot tell a program's
    /// request from the user's: `read_clipboard_cb` is handed only an opaque request
    /// (libghostty's own tagged union) for a paste and an `OSC 52` read alike, and
    /// `write_clipboard_cb` no kind at all. **For a write, and for a read that
    /// libghostty completes without asking (`clipboard-read = allow`), this
    /// configuration is the only line.** Only a request libghostty puts to the host for
    /// confirmation reaches `confirm_read_clipboard_cb`, the one callback told the kind,
    /// where `passesOn` refuses a viewer's `OSC 52` request as well.
    nonisolated static let viewerOverlay = "clipboard-read = deny\nclipboard-write = deny\n"

    /// A viewer surface's configuration, built and checked: the app's, with
    /// `viewerOverlay` loaded from a file of this process's own (libghostty has no
    /// setter) in its temporary directory, which is removed once loaded. Nil, and
    /// nothing kept, unless libghostty resolves both `clipboard-read` and
    /// `clipboard-write` of the configuration built to `deny`: a file that was not
    /// written, or not read (libghostty takes a missing path for no values), fails
    /// closed.
    private static func buildViewerConfig() -> ghostty_config_t? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wietty-viewer-surface-\(getpid())-\(UUID().uuidString).cfg")
        do {
            try viewerOverlay.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.fault("the viewer surface configuration could not be written: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let config = buildConfig(viewer: url)
        try? FileManager.default.removeItem(at: url)
        let access = clipboardAccess(in: config)
        guard let config, isClosed(read: access.read, write: access.write) else {
            log.fault("the viewer surface configuration resolves clipboard-read \(access.read ?? "nil", privacy: .public), clipboard-write \(access.write ?? "nil", privacy: .public); no viewer surface is made with it")
            if let config { ghostty_config_free(config) }
            return nil
        }
        return config
    }

    /// Whether a configuration that resolves these values keeps a program away from
    /// the clipboard: both `deny`, and nothing else.
    nonisolated static func isClosed(read: String?, write: String?) -> Bool {
        read == "deny" && write == "deny"
    }

    /// What the viewer configuration in use resolves, nil with none. For the suite.
    var viewerClipboardAccess: (read: String?, write: String?)? {
        viewerConfig.map { Self.clipboardAccess(in: $0) }
    }

    /// What a configuration made of one file alone resolves for `clipboard-read` and
    /// `clipboard-write`, for the suite. Nil for a key the getter refuses.
    static func clipboardAccess(loading file: URL) -> (read: String?, write: String?) {
        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        return clipboardAccess(in: config)
    }

    /// libghostty's resolved `clipboard-read` and `clipboard-write`, as the names of
    /// their cases (`ask`, `allow`, `deny`). Nil for a key the getter refuses.
    private static func clipboardAccess(in config: ghostty_config_t?) -> (read: String?, write: String?) {
        guard let config else { return (nil, nil) }
        func value(_ key: String) -> String? {
            var value: UnsafePointer<CChar>?
            let found = key.withCString { ghostty_config_get(config, &value, $0, UInt(strlen($0))) }
            guard found, let value else { return nil }
            return String(cString: value)
        }
        return (value("clipboard-read"), value("clipboard-write"))
    }

    var desktopNotifications: (effective: Bool, userConfig: Bool) {
        // The user's configuration is rebuilt rather than remembered, because this
        // is read when the Settings tab is drawn and not on any hot path, and a
        // remembered copy would go stale the moment they edited their own config.
        let theirs = Self.buildConfig(overlay: nil)
        defer { ghostty_config_free(theirs) }
        return (Self.desktopNotifications(in: config), Self.desktopNotifications(in: theirs))
    }

    /// libghostty's answer for one key. `ghostty_config_get` exposes a subset of the
    /// configuration and this key is in it, which is measured rather than assumed:
    /// neighbouring keys are not, so this cannot be generalised without checking the
    /// one being added.
    ///
    /// A getter that refuses leaves `true`, libghostty's own default, which is also
    /// what a config setting nothing resolves to.
    private static func desktopNotifications(in config: ghostty_config_t?) -> Bool {
        guard let config else { return true }
        var value = true
        let key = "desktop-notifications"
        _ = key.withCString { ghostty_config_get(config, &value, $0, UInt(strlen($0))) }
        return value
    }

    var graphemeClustering: Bool { Self.graphemeClustering(in: config) }

    /// What a configuration made of one file alone resolves for grapheme
    /// clustering. The user's own Ghostty config is not loaded, so this answers for
    /// the file and nothing else, which is what lets the suite pin both values of
    /// the key without depending on whose machine it runs on.
    static func graphemeClustering(loading file: URL) -> Bool {
        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        return graphemeClustering(in: config)
    }

    /// libghostty's answer for `grapheme-width-method`, as the one thing the rest
    /// of the app needs from it. The getter hands back an enum as the name of its
    /// case, a C string libghostty owns, and this key is one it exposes: measured,
    /// as `desktopNotifications(in:)` says each key has to be.
    ///
    /// Anything but `legacy` is true, including a getter that refuses, because
    /// `unicode` is libghostty's default and what a surface then starts with.
    private static func graphemeClustering(in config: ghostty_config_t?) -> Bool {
        guard let config else { return true }
        var value: UnsafePointer<CChar>?
        let key = "grapheme-width-method"
        _ = key.withCString { ghostty_config_get(config, &value, $0, UInt(strlen($0))) }
        guard let value else { return true }
        return String(cString: value) != "legacy"
    }

    func reloadConfig() {
        guard let app else { return }
        let rebuilt = Self.buildConfig()
        let viewerRebuilt = Self.buildViewerConfig()
        // The app first, then every surface. libghostty copies what it needs out of
        // the config, so the old one can be freed once both have been handed the new
        // one, and freeing it before the surfaces are updated would leave them
        // reading it.
        //
        // A viewer surface gets the viewer's configuration, after the app's update
        // (which hands every surface the app's: measured, a viewer left out of this
        // loop takes a program's `OSC 52` write after a reload) and in the same main
        // turn, so no
        // clipboard request of its program is handled under the app's in between. With
        // no viewer configuration rebuilt (one that does not resolve both keys to deny
        // is not built) it is given the previous one again, which passed that check
        // when it was built: a viewer keeps the clipboard closed, and misses only the
        // reload's other changes (fonts, colours) until a later reload succeeds.
        ghostty_app_update_config(app, rebuilt)
        for (id, surface) in surfaces {
            if viewers.contains(id) {
                if let current = viewerRebuilt ?? viewerConfig {
                    ghostty_surface_update_config(surface.handle, current)
                }
            } else {
                ghostty_surface_update_config(surface.handle, rebuilt)
            }
        }
        if let previous = config { ghostty_config_free(previous) }
        config = rebuilt
        if let viewerRebuilt {
            if let previous = viewerConfig { ghostty_config_free(previous) }
            viewerConfig = viewerRebuilt
        }
        padding = GhosttyPadding.resolveHostConfiguration()
        background = Self.background(in: rebuilt) ?? .black
        backgroundOpacity = Self.backgroundOpacity(in: rebuilt)
        configGeneration += 1
        // Each surface takes its metrics again under the new configuration: its
        // padding bounds start over and the configured padding is checked afresh.
        // Measured, libghostty keeps an existing surface's padding through a reload,
        // so a changed one is disproved by the surface's reports and the metrics keep
        // what it really uses. A surface with no window keeps its last scale. A font
        // change arrives later on its own, as a cell size action.
        for surface in surfaces.values {
            surface.view.configuredBackground = background
            surface.view.backgroundOpacity = backgroundOpacity
            surface.view.synchronizeMetrics()
        }
    }

    /// What a configuration made of one file alone resolves for `background`, for
    /// the suite: the user's own Ghostty config is not loaded.
    static func background(loading file: URL) -> NSColor? {
        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        return background(in: config)
    }

    /// What a configuration made of one file alone resolves for
    /// `background-opacity`, for the suite.
    static func backgroundOpacity(loading file: URL) -> Double {
        let config = ghostty_config_new()
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        return backgroundOpacity(in: config)
    }

    /// libghostty's resolved `background-opacity`, which `ghostty_config_get`
    /// exposes as a `double` (measured on the pinned 1.3.2: 1.0 by default, 0.75 for
    /// a file setting 0.75; read as a `float` it gives 0). 1 when the getter refuses.
    private static func backgroundOpacity(in config: ghostty_config_t?) -> Double {
        guard let config else { return 1 }
        var value = 1.0
        let key = "background-opacity"
        let found = key.withCString { ghostty_config_get(config, &value, $0, UInt(strlen($0))) }
        return found ? value : 1
    }

    /// The colour a colour change action carries, when it is the background's: a
    /// program set it with `OSC 11`, or reset it (libghostty then reports the
    /// configured colour). Nil for the foreground or the cursor. Takes the kind's
    /// raw value so the suite can call it without GhosttyKit.
    nonisolated static func background(changeKind kind: Int32, r: UInt8, g: UInt8, b: UInt8) -> NSColor? {
        guard kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND.rawValue else { return nil }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// libghostty's resolved `background`, which `ghostty_config_get` exposes as
    /// three bytes (measured on the pinned 1.3.2). Read as sRGB, Ghostty's default
    /// `window-colorspace`. Nil when the getter refuses.
    private static func background(in config: ghostty_config_t?) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        let key = "background"
        let found = key.withCString { ghostty_config_get(config, &color, $0, UInt(strlen($0))) }
        guard found else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                       blue: CGFloat(color.b) / 255, alpha: 1)
    }

    // MARK: - Surfaces

    /// The surface of terminal `id`, joined to its stream: the bridge is built and
    /// listening first, then the surface runs the helper pointed at it
    /// (`PaneBridges.command`). A surface that cannot be created takes its bridge
    /// with it.
    func createSurface(id: String, directory: URL, title: String?) throws {
        guard let bridges, app != nil, surfaces[id] == nil else { throw SurfaceHostError.surfaceFailed }
        // The pane's grid shows through the same `impose` any caller has.
        let command = try bridges.open(session: id) { [weak self] grid in
            self?.impose(grid: grid, on: id)
        }
        do {
            try createSurface(id: id, command: command, directory: directory, title: title)
        } catch {
            bridges.close(session: id)
            throw error
        }
    }

    /// A surface running `command` in `directory`, with no bridge: what the surface
    /// shows is whatever `command` prints. Not part of `TerminalSurfaceHosting`; the
    /// coexistence check and the imposed grid measurement drive a surface this way.
    /// `destroySurface(id:)` frees it as any other.
    func createSurface(id: String, command: String, directory: URL, title: String?) throws {
        try makeSurface(id: id, command: command, directory: directory, title: title,
                        viewer: false, grid: nil)
    }

    /// A surface that shows a terminal of another Mac: it runs `command`, the helper
    /// pointed at a bridge its owner made, and belongs to no session of this Mac's.
    /// Not part of `TerminalSurfaceHosting`.
    ///
    /// The host records that `id` is a viewer, and for it drops what would reach the
    /// app's terminals, its store or Notification Center: titles, bells, desktop
    /// notifications, close requests and `onInput` (`passesOn`). A program's `OSC 52`
    /// read and write are refused by libghostty itself (`viewerOverlay`); the user's
    /// own copy and paste work as in the own pane. Cell size, metrics, background,
    /// rendering and `impose(grid:on:)` work as for any surface.
    ///
    /// - Parameter grid: the pane's grid (`OwnPaneGrid(viewer: true, ...)`), told the
    ///   pane's size as the surface comes on and off display and every user action, as
    ///   `PaneBridges` grids are for the own pane. The host keeps it until
    ///   `destroySurface(id:)` and never stops it; its owner does.
    func createViewerSurface(id: String, command: String, grid: OwnPaneGrid?) throws {
        try makeSurface(id: id, command: command,
                        directory: FileManager.default.homeDirectoryForCurrentUser,
                        title: nil, viewer: true, grid: grid)
    }

    private func makeSurface(id: String, command: String, directory: URL, title: String?,
                             viewer: Bool, grid: OwnPaneGrid?) throws {
        guard let app else { throw SurfaceHostError.surfaceFailed }
        guard surfaces[id] == nil else { throw SurfaceHostError.surfaceFailed }
        if viewer && viewerConfig == nil { throw SurfaceHostError.surfaceFailed }
        // A viewer is recorded, with its grid, before anything of the surface exists,
        // so every report of it (a pane change, a user action, an event) finds it a
        // viewer, however early it comes. Forgotten again if the surface fails.
        if viewer {
            viewers.insert(id)
            viewerGrids[id] = grid
        }
        var created = false
        defer {
            if viewer && !created {
                viewers.remove(id)
                viewerGrids[id] = nil
            }
        }

        // A size, not zero: a surface created against a zero sized view stays
        // blank even after it is laid out, unless the metrics are sent again. The
        // pane's constraints replace this on the first layout pass.
        let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                      host: self,
                                      id: id)
        // The user's keys, clicks, pastes and drops, to the pane's grid.
        view.onUserAction = { [weak self] in self?.userActed(in: id) }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        // Comes back on every action callback for this surface, and is how a
        // callback finds the session id it belongs to. The view is retained by
        // `surfaces` for as long as the surface exists.
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.working_directory = UnsafePointer(strdup(directory.path))
        config.command = UnsafePointer(strdup(command))
        // The IO backend is left at whatever `ghostty_surface_config_new` sets,
        // which is exec. The pinned wrapper also carries a fork only host managed
        // backend; it is deliberately not used, so that the byte path depends on
        // the upstream API surface alone and stays replaceable.
        defer {
            free(UnsafeMutableRawPointer(mutating: config.working_directory))
            free(UnsafeMutableRawPointer(mutating: config.command))
        }

        guard let handle = ghostty_surface_new(app, &config) else {
            throw SurfaceHostError.surfaceFailed
        }
        if viewer, let viewerConfig {
            // In the creating main turn: libghostty handles a program's clipboard
            // request on a later one (in `ghostty_app_tick`), under this configuration.
            ghostty_surface_update_config(handle, viewerConfig)
        }
        created = true
        surfaces[id] = Surface(view: view, handle: handle)
        if let title { setTitle(title, for: id) }
        view.configuredBackground = background
        view.backgroundOpacity = backgroundOpacity
        view.adopt(surface: handle)
    }

    func destroySurface(id: String) {
        // The bridge first, as the relay's socket used to be closed first: the
        // helper sees its socket end and exits, and a write of the bridge's that is
        // blocked on a surface no longer reading fails at once rather than outlive
        // the surface. A close request libghostty raises for that exit arrives on a
        // later main turn and finds no surface. Also for a surface that is already
        // gone, since stopping a bridge twice is nothing.
        bridges?.close(session: id)
        viewers.remove(id)
        viewerGrids[id] = nil
        viewerGridObservers[id] = nil
        guard let surface = surfaces.removeValue(forKey: id) else { return }
        titles[id] = nil
        // The view's pointer is cleared before the free, because a view can still
        // be laid out on its way out of the hierarchy and every one of its calls
        // would then be a use after free.
        surface.view.detachSurface()
        surface.view.removeFromSuperview()
        ghostty_surface_free(surface.handle)
        // Drains libghostty's app mailbox while no surface has the freed address.
        // Messages the surface's IO thread queued before the free (a title, a bell, a
        // background, a program's clipboard request) are addressed by the surface
        // pointer, and the allocator often hands the next surface that very address: a
        // surface created before the next tick (in this main turn) received them as its
        // own (R8 of the step 5 measurement, final runs, 50 cycles a run: without this
        // tick 2 to 14 crossed titles, and a viewer's clipboard write reaching an own
        // surface in 2 to 10; with it 0 in 18 runs, 900 cycles). Ticked now, libghostty
        // finds no surface at that address and drops them.
        //
        // Safe to do here: every runtime callback a tick raises hops to the main queue
        // before it touches the host, except a clipboard read, which completes on the
        // spot for a surface that still exists and changes none of the host's state.
        // Nothing in this host calls `destroySurface` from inside a tick.
        if drainsOnDestroy, let app { ghostty_app_tick(app) }
    }

    /// Whether `destroySurface` drains the app's mailbox. Fixed at `init`: off only
    /// for the R8 measurement, which shows what happens without it.
    let drainsOnDestroy: Bool

    func view(id: String) -> NSView? { surfaces[id]?.view }

    func size(id: String) -> TerminalSize? {
        guard let surface = surfaces[id] else { return nil }
        let size = ghostty_surface_size(surface.handle)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return TerminalSize(cols: Int(size.columns), rows: Int(size.rows))
    }

    func metrics(id: String) -> SurfaceMetrics? { surfaces[id]?.view.metrics }

    func impose(grid: TerminalSize?, on id: String) {
        surfaces[id]?.view.imposedGrid = grid
    }

    /// Everything `ghostty_surface_size` reports for one surface, in pixels, or nil
    /// for a surface this host does not have.
    ///
    /// For one caller, the imposed grid measurement (`scripts/imposed-grid-check.sh`),
    /// which has to see the cell size and the pixel size the grid was derived from,
    /// not only the grid. Not part of `TerminalSurfaceHosting`: the pane uses
    /// `metrics(id:)` and `impose(grid:on:)`.
    func pixelMetrics(id: String) -> (columns: Int, rows: Int, widthPx: Int, heightPx: Int,
                                      cellWidthPx: Int, cellHeightPx: Int)? {
        guard let surface = surfaces[id] else { return nil }
        let size = ghostty_surface_size(surface.handle)
        return (Int(size.columns), Int(size.rows), Int(size.width_px), Int(size.height_px),
                Int(size.cell_width_px), Int(size.cell_height_px))
    }

    /// Whether a read of `maxLines` rows has to reach past the grid into
    /// scrollback.
    ///
    /// Strictly greater, and the boundary is the whole point: `maxLines` exactly
    /// equal to the grid's height is the visible screen, which the cheap viewport
    /// read answers in full. Reading this as `>=` sends a read of exactly the
    /// grid down the whole screen path, roughly 34 ms of main actor time against
    /// 0.14 ms.
    ///
    /// Extracted from `readText` so the boundary can be asserted without a live
    /// surface, a Metal device, or a deep scrollback to measure against.
    nonisolated static func readsScrollback(maxLines: Int, gridRows: Int) -> Bool {
        maxLines > gridRows
    }

    /// The last `maxLines` rows of the surface's own screen as plain text, or nil
    /// for a surface with no grid. Empty for a surface that is not on screen,
    /// which libghostty reads as blank.
    ///
    /// Nothing the app does reads a terminal this way any more. The core keeps a
    /// screen model per terminal and answers from that, for exactly the reason in
    /// the line above: a surface only answers while it is displayed, in plain
    /// text, with no cursor. This stays for one caller, the coexistence check
    /// (`scripts/coexistence-check.sh`), which has to ask the surface itself what
    /// it drew in order to compare it with the model. That is also why it is not
    /// part of `TerminalSurfaceHosting`.
    ///
    /// Two reads, because they cost very differently and only one of them can see
    /// history. `ghostty_surface_read_text` takes a selection, and a selection's
    /// points carry a coordinate mode as well as coordinates: `EXACT` addresses a
    /// row, while `TOP_LEFT` and `BOTTOM_RIGHT` mean "the extreme of this space"
    /// and ignore x and y. A `GHOSTTY_POINT_SCREEN` selection between those two
    /// extremes is therefore the whole screen, scrollback included, with no height
    /// getter needed. `EXACT` cannot substitute: measured against a 50,000 line
    /// scrollback in a 28 row grid, `SCREEN` with `EXACT` y up to 9999 returned 28
    /// rows, so it clamps to the grid and cannot address history at all.
    ///
    /// Measured on that same 50,000 line scrollback, on the main actor:
    /// the viewport read is 0.14 ms and the whole screen read is 29 ms, plus 5 ms to
    /// decode and split it. So the viewport read is used whenever it can answer the
    /// question, which is every call asking for no more rows than the grid has, the
    /// boundary included; see `readsScrollback`.
    func readText(id: String, maxLines: Int) -> [String]? {
        guard maxLines > 0, let surface = surfaces[id] else { return nil }
        let size = ghostty_surface_size(surface.handle)
        guard size.columns > 0, size.rows > 0 else { return nil }

        var selection = ghostty_selection_s()
        selection.rectangle = false
        if Self.readsScrollback(maxLines: maxLines, gridRows: Int(size.rows)) {
            selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN,
                                                 coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                                                 x: 0, y: 0)
            selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN,
                                                     coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                                                     x: 0, y: 0)
        } else {
            selection.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT,
                                                 coord: GHOSTTY_POINT_COORD_EXACT,
                                                 x: 0,
                                                 y: UInt32(Int(size.rows) - maxLines))
            selection.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT,
                                                     coord: GHOSTTY_POINT_COORD_EXACT,
                                                     x: UInt32(size.columns - 1),
                                                     y: UInt32(size.rows - 1))
        }

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface.handle, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface.handle, &text) }
        guard let pointer = text.text, text.text_len > 0 else {
            return []
        }
        let joined = String(decoding: UnsafeRawBufferPointer(start: pointer,
                                                             count: Int(text.text_len)),
                            as: UTF8.self)
        let rows = joined.components(separatedBy: "\n")
        return rows.count > maxLines ? Array(rows.suffix(maxLines)) : rows
    }

    /// Records a surface's label, and mirrors it onto the view so assistive
    /// technology can read it. libghostty has no title setter, so this is as far
    /// as a title can travel: the terminal itself never learns it.
    private func setTitle(_ title: String, for id: String) {
        titles[id] = title
        surfaces[id]?.view.setAccessibilityLabel(title)
    }

    // MARK: - Tick and drawing

    /// Drains libghostty's own event loop. Main thread only, and only when
    /// libghostty asked for it through `wakeup_cb` (`destroySurface` ticks on its
    /// own, without the redraw).
    private func tickAndRedrawAll() {
        guard let app else { return }
        ghostty_app_tick(app)
        for surface in surfaces.values { surface.view.requestRedraw() }
    }

    // MARK: - Actions

    /// What a libghostty action means to this host. The payload is copied out of
    /// the C structure before the hop to the main queue, because the pointers in
    /// it are only valid for the duration of the callback.
    enum SurfaceEvent: Sendable {
        case render
        case bell
        case notification(title: String, body: String)
        case title(String)
        case cellSize
        case background(r: UInt8, g: UInt8, b: UInt8)
    }

    /// libghostty's runtime action callback. Called on whichever thread raised
    /// the action, so it resolves the session id synchronously and hands the rest
    /// to the main actor.
    ///
    /// Returns true only for the tags handled here. The spike's version returned
    /// false unconditionally and read union members regardless of the tag, which
    /// is undefined for every tag but the one that was set.
    private nonisolated static func dispatch(target: ghostty_target_s,
                                             action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return false }
        let id = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().id

        let event: SurfaceEvent
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            event = .render
        case GHOSTTY_ACTION_RING_BELL:
            event = .bell
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // A body is what there is to show, so a notification without one does not
            // become a banner. It becomes a bell instead of nothing: something did
            // happen on this terminal, and returning here dropped the event before
            // the store saw it, so the row lost its attention mark too. A program that
            // signalled got no banner, no mark in the sidebar, and no trace.
            //
            // Empty counts as absent. libghostty passes a non-null empty C string for
            // an `OSC 9;` carrying no payload, so checking only for null let a
            // textless banner through. A missing title is kept: `OSC 9;text` sets only
            // the body, and libghostty passes an empty title in that case.
            let payload = action.action.desktop_notification
            let body = payload.body.map { String(cString: $0) } ?? ""
            event = body.isEmpty
                ? .bell
                : .notification(title: payload.title.map { String(cString: $0) } ?? "",
                                body: body)
        case GHOSTTY_ACTION_CELL_SIZE:
            // The font metrics changed, so the grid has to be derived again even
            // though the view did not move.
            event = .cellSize
        case GHOSTTY_ACTION_COLOR_CHANGE:
            // Only the background matters here: it is the margin's colour.
            let change = action.action.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return false }
            event = .background(r: change.r, g: change.g, b: change.b)
        case GHOSTTY_ACTION_SET_TITLE:
            guard let pointer = action.action.set_title.title else { return false }
            event = .title(String(cString: pointer))
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Deliberately unhandled, and false rather than true so libghostty
            // knows the host did not show anything.
            //
            // libghostty means "the process this surface was running has ended,
            // show the user". On this substrate that process is `wietty-pty`,
            // which ends when its bridge's socket closes: it is downstream of the
            // terminal ending rather than the cause of it, and it also fires when
            // the app itself tears a terminal down. The row's own state comes from
            // the pty's EOF instead, through `GhosttyService.reap` and the monitor,
            // which is the one path that knows whether the *shell* exited. Drawing
            // a second "the command exited" notice over the surface would cover
            // the last screen that command printed, which is the thing worth
            // reading. `close_surface_cb` is where the close request is honoured.
            return false
        default:
            return false
        }

        // The id is carried rather than the view: after the hop the surface may
        // have been destroyed, and a stale pointer would be a use after free
        // where a missing dictionary entry is simply nothing to do.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GhosttySurfaceHost.current?.apply(event, to: id) }
        }
        return true
    }

    /// A callback of a surface, as far as passing it on depends on whether the surface
    /// is a viewer of another Mac.
    enum SurfaceCallback: Equatable, Sendable {
        case render, cellSize, background, grid, metrics, userAction
        case title, bell, desktopNotification, closeRequest, input
        /// libghostty asking whether to complete a clipboard read it judged unsafe or
        /// not yet allowed, of this kind (nil: one this build does not know).
        case confirmClipboard(ClipboardRequest?)
    }

    /// libghostty's `ghostty_clipboard_request_e`.
    enum ClipboardRequest: Equatable, Sendable {
        /// The user's paste (`paste_from_clipboard`).
        case paste
        /// A program's `OSC 52` read or write.
        case osc52Read, osc52Write

        /// - Parameter kind: the C enum's raw value.
        nonisolated init?(kind: Int) {
            switch kind {
            case Int(GHOSTTY_CLIPBOARD_REQUEST_PASTE.rawValue): self = .paste
            case Int(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ.rawValue): self = .osc52Read
            case Int(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE.rawValue): self = .osc52Write
            default: return nil
            }
        }
    }

    /// Whether the host passes `callback` on, for a surface that is a viewer of another
    /// Mac or one of this Mac's own terminals. A viewer belongs to no session here, so
    /// nothing that would reach `GhosttyService`, the store, `GhosttyMonitor` or
    /// Notification Center is passed on, and a program's clipboard request is never put
    /// to the user. Everything that draws and sizes the surface, and the user's own
    /// actions, are passed on for both.
    nonisolated static func passesOn(_ callback: SurfaceCallback, viewer: Bool) -> Bool {
        guard viewer else { return true }
        switch callback {
        case .render, .cellSize, .background, .grid, .metrics, .userAction:
            return true
        case .title, .bell, .desktopNotification, .closeRequest, .input:
            return false
        case .confirmClipboard(let request):
            return request == .paste
        }
    }

    /// The callback an action of libghostty is, for `passesOn`.
    nonisolated static func callback(for event: SurfaceEvent) -> SurfaceCallback {
        switch event {
        case .render: .render
        case .bell: .bell
        case .notification: .desktopNotification
        case .title: .title
        case .cellSize: .cellSize
        case .background: .background
        }
    }

    private func passesOn(_ callback: SurfaceCallback, for id: String) -> Bool {
        Self.passesOn(callback, viewer: viewers.contains(id))
    }

    private func apply(_ event: SurfaceEvent, to id: String) {
        guard let surface = surfaces[id], passesOn(Self.callback(for: event), for: id) else { return }
        switch event {
        case .render:
            surface.view.requestRedraw()
        case .bell:
            onBell?(id)
        case .notification(let title, let body):
            onDesktopNotification?(id, title, body)
        case .title(let title):
            setTitle(title, for: id)
            onTitle?(id, title)
        case .cellSize:
            surface.view.synchronizeMetrics()
        case .background(let r, let g, let b):
            surface.view.programBackground = Self.background(
                changeKind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND.rawValue, r: r, g: g, b: b)
        }
    }

    /// Called by a view whose grid changed. Passed on as `onResized`, which resizes
    /// nothing.
    fileprivate func report(grid: TerminalSize, for id: String) {
        guard surfaces[id] != nil, passesOn(.grid, for: id) else { return }
        viewerGridObservers[id]?(grid)
        onResized?(id, grid)
    }

    /// Tells `handler` every grid the viewer surface `id` reports from now on, as
    /// `onResized` is told: after `ghostty_surface_set_size`, whenever the grid changed.
    /// For the remote pane, which holds a snapshot until its surface has the grid the
    /// view was given. Forgotten at `destroySurface`. Not part of
    /// `TerminalSurfaceHosting`.
    func observeViewerGrid(id: String, _ handler: @escaping @MainActor (TerminalSize) -> Void) {
        guard viewers.contains(id) else { return }
        viewerGridObservers[id] = handler
    }

    /// Called by a view whose metrics changed. The grid that fits the pane may have
    /// moved with them (a font size, a padding, another scale).
    fileprivate func reportMetrics(for id: String) {
        guard surfaces[id] != nil, passesOn(.metrics, for: id) else { return }
        onMetricsChanged?(id)
        paneChanged(for: id)
    }

    /// Called by a view on every key the user typed: `onInput`, for this Mac's own
    /// terminals only.
    fileprivate func userTyped(in id: String) {
        guard passesOn(.input, for: id) else { return }
        onInput?(id)
    }

    // MARK: - The pane's grid

    /// The pane around a surface changed size, or the surface came on or left
    /// display: its pane's grid is told the grid that fits the pane now, nil when the
    /// surface is not on display. A surface with no bridge (a measurement's) has none.
    fileprivate func paneChanged(for id: String) {
        guard let view = surfaces[id]?.view, let grid = grid(for: id) else { return }
        grid.paneChanged(ownGrid: view.ownGrid)
    }

    /// The user typed, clicked, pasted or dropped something in the surface: a pane
    /// that does not own the grid claims it.
    fileprivate func userActed(in id: String) {
        guard passesOn(.userAction, for: id) else { return }
        grid(for: id)?.userActed()
    }

    /// The pane's grid of surface `id`: the one its viewer entry was given, or the own
    /// pane's bridge's.
    private func grid(for id: String) -> OwnPaneGrid? {
        viewers.contains(id) ? viewerGrids[id] : bridges?.grid(for: id)
    }

    // MARK: - Close requests

    /// libghostty asking the host to close a surface.
    ///
    /// The userdata of a surface scoped runtime callback is the SURFACE's own
    /// userdata, not the app's: libghostty passes `surface.userdata` to
    /// `close_surface_cb`, `read_clipboard_cb` and `confirm_read_clipboard_cb`,
    /// and the app's only to `wakeup_cb`. This host sets the surface userdata to
    /// the view (see `createSurface`), so that is what these three cast to.
    /// Verified against the pinned package's own AppKit wrapper, which casts
    /// exactly this argument to its per surface bridge while casting the wakeup's
    /// to its app object.
    private nonisolated static func closeSurface(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        // The id, not the view: after the hop the surface may be gone, and a
        // stale object pointer would be a use after free where a missing
        // dictionary entry is simply nothing to do. Reading it here is safe
        // because the view is alive for the duration of the callback and `id` is
        // an immutable nonisolated field.
        let id = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().id
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GhosttySurfaceHost.current?.requestClose(id) }
        }
    }

    /// Reports a close request, and frees nothing.
    ///
    /// Not freeing is the point. This fires when the surface's command exits,
    /// which on this substrate is the helper losing its bridge, and the last
    /// screen a command left behind is what the user wants to read. The handler's
    /// job is to retire the terminal, and `close`/`closeAll` remain the only
    /// things that destroy a surface.
    private func requestClose(_ id: String) {
        guard surfaces[id] != nil, passesOn(.closeRequest, for: id) else { return }
        onCloseRequested?(id)
    }

    // MARK: - Clipboard

    /// libghostty asking for the clipboard, for a paste binding or an OSC 52 read.
    ///
    /// Served only on the main thread, and refused otherwise rather than guessed
    /// at. libghostty raises this while draining its own event loop, which this
    /// host only ever does from `ghostty_app_tick` on the main thread, so the main
    /// thread is the expected case; `NSPasteboard` is not documented as thread
    /// safe and completing the request touches main actor state.
    ///
    /// Completed with `confirmed: false`, which is not a refusal: it asks
    /// libghostty to apply its own unsafe paste check and come back through
    /// `confirm_read_clipboard_cb` if the text could run as commands the moment it
    /// lands. Passing true here would skip that check for every paste.
    ///
    /// Not told whether the request is a paste or an `OSC 52` read (`request` is
    /// libghostty's own opaque union), so nothing here can refuse a program's read. A
    /// viewer surface's are always pastes only because its configuration has
    /// libghostty refuse a read before it gets here (`viewerOverlay`). Under
    /// `clipboard-read = ask` a read that got here would still be stopped at the
    /// confirmation; under `allow` it would not be, as libghostty completes it unasked.
    private nonisolated static func readClipboard(userdata: UnsafeMutableRawPointer?,
                                                  request: UnsafeMutableRawPointer?) -> Bool {
        guard Thread.isMainThread, let userdata, let request else { return false }
        let view = RawPointerBox(pointer: userdata)
        let pending = RawPointerBox(pointer: request)
        return MainActor.assumeIsolated {
            let surfaceView = Unmanaged<GhosttySurfaceView>.fromOpaque(view.pointer)
                .takeUnretainedValue()
            guard let surface = surfaceView.surfaceHandle,
                  let pasteboard = GhosttySurfaceHost.current?.pasteboard,
                  let text = pasteboard.string(forType: .string) else { return false }
            text.withCString {
                ghostty_surface_complete_clipboard_request(surface, $0, pending.pointer, false)
            }
            return true
        }
    }

    /// libghostty judged a pending paste unsafe and is asking whether to go ahead.
    ///
    /// Answered by the user, because there is no safe default. The text holds
    /// newlines or control characters, so a shell runs it the instant it arrives,
    /// and the request can come from an OSC 52 sequence a remote program emitted
    /// rather than from a key the user pressed.
    ///
    /// Deliberately asked on a later main queue turn. A modal alert runs the run
    /// loop, and this arrives inside `ghostty_app_tick`, so showing it here would
    /// let a wakeup tick libghostty again from inside its own tick. The request
    /// pointer is libghostty's, stays valid until it is completed, and completing
    /// late is exactly what it is for.
    ///
    /// The one clipboard callback told the request's kind, and reached only by a read
    /// libghostty asks about (an unsafe paste, or an `OSC 52` read under
    /// `clipboard-read = ask`). A viewer surface's program request is not put to the
    /// user (`passesOn`): it is left uncompleted, which is how libghostty reads a
    /// refusal, and no alert is shown. A second line for reads under `ask` only; never
    /// for a write, or a read under `allow`.
    private nonisolated static func confirmReadClipboard(userdata: UnsafeMutableRawPointer?,
                                                         string: UnsafePointer<CChar>?,
                                                         request: UnsafeMutableRawPointer?,
                                                         kind: ClipboardRequest?) {
        guard let userdata, let string, let request else { return }
        let id = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().id
        // Copied here: the C string's lifetime is this call, not the hop.
        let text = String(cString: string)
        let pending = RawPointerBox(pointer: request)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GhosttySurfaceHost.current?.confirmPaste(text, request: pending, kind: kind, for: id)
            }
        }
    }

    private func confirmPaste(_ text: String, request: RawPointerBox, kind: ClipboardRequest?,
                              for id: String) {
        guard surfaces[id] != nil, passesOn(.confirmClipboard(kind), for: id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste into the terminal?"
        alert.informativeText = """
            The text on the clipboard contains line breaks or control characters, \
            so a shell will run it as soon as it arrives rather than waiting for \
            you to press return.
            """
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            // The request is left uncompleted, which is how libghostty reads a
            // refusal. It keeps the small allocation behind the request pointer
            // until the surface is freed; there is no cancel entry point in the
            // C API to hand it back.
            return
        }
        // Re-resolved after the modal, not captured before it: the alert ran the
        // run loop, so the terminal can have been closed while it was up and the
        // handle from before would be freed.
        guard let surface = surfaces[id] else { return }
        text.withCString {
            ghostty_surface_complete_clipboard_request(surface.handle, $0, request.pointer, true)
        }
    }

    deinit {
        // Only the app and the config, in that order, and not the surfaces.
        // Freeing a surface means clearing the borrowed pointer its view holds
        // first, which is main actor work a nonisolated deinit cannot do safely.
        // `destroySurface` owns that, and `GhosttyService.closeAll` calls it for
        // every terminal on teardown, so a surface reaching here is a leak at
        // process exit rather than a live one.
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        if let viewerConfig { ghostty_config_free(viewerConfig) }
    }
}

/// A raw pointer carried across an isolation boundary.
///
/// Pointers are deliberately not `Sendable`, and libghostty hands this host two
/// that have to cross onto the main actor: the surface userdata a callback
/// identifies its surface by, and the opaque clipboard request it wants handed
/// back. Both are owned by libghostty for longer than the crossing, and neither is
/// dereferenced anywhere but the main actor, which is what makes the `@unchecked`
/// true rather than merely convenient.
private struct RawPointerBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

// MARK: - Surface view

/// The `NSView` a surface is created with.
///
/// libghostty requires one and keeps it for the surface's whole life: the macOS
/// platform union is `{ void *nsview; }`, so there is no surface without a view.
/// This view drives drawing, keeps size and scale in sync, and forwards keyboard
/// input, because libghostty installs nothing on the view and nothing reaches the
/// shell until the host forwards it.
///
/// It is added to and removed from the window's view hierarchy by the pane. It is
/// never recreated: the spike proved a live surface survives being re-parented,
/// including into a different `NSWindow`, and rebuilding on attach is what would
/// wipe a pane's scrollback.
@MainActor
final class GhosttySurfaceView: NSView, GridSizedSurface {
    /// The session this surface belongs to. Immutable and read from libghostty's
    /// action callback, which arrives on libghostty's own thread.
    nonisolated let id: String

    private weak var host: GhosttySurfaceHost?
    /// Borrowed, not owned. `GhosttySurfaceHost` frees the surface and clears
    /// this first, so nothing here can reach a freed one.
    private var surface: ghostty_surface_t?
    private var redrawScheduled = false
    private var lastGrid: TerminalSize?
    /// The metrics last reported through `onMetricsChanged`.
    private var lastMetrics: SurfaceMetrics?
    /// The backing scale `synchronizeMetrics` last handed libghostty, so the scale
    /// the surface renders at. Nil before the first one.
    private var renderScale: Double?
    /// The surface's metrics as of the last `synchronizeMetrics`. Stored there, not
    /// derived on read, so reading them has no side effect.
    private(set) var metrics: SurfaceMetrics?
    /// What this surface's reports prove about its true padding, per axis, and what
    /// those bounds were gathered for: the cell size, the scale and the host's
    /// configuration generation. A change of any starts them over.
    private var paddingWindows = (x: PaddingWindow(), y: PaddingWindow())
    private var paddingWindowsKey: [Double]?
    /// Each logged once per surface, as they are found on every layout pass.
    private var reportedPaddingMismatch = false
    private var reportedClamp = false
    /// What the closed loop may still correct of the imposed size: twice per grid
    /// imposed and per metrics key (`ImposedSizeCorrections`).
    private var corrections = ImposedSizeCorrections()
    private static let maxCorrections = ImposedSizeCorrections.limit

    /// The grid imposed on this surface, kept whether or not it is on display. As
    /// asked: the size it gets is that of `shownGrid`, which is this clamped.
    var imposedGrid: TerminalSize? {
        didSet {
            guard imposedGrid != oldValue else { return }
            corrections.gridImposed()
            refreshImposedSize()
        }
    }
    /// The grid the view is sized for: `imposedGrid` held to at least 1 by 1, at
    /// most the protocol's 10,000 per side, and at most what the renderer's texture
    /// can hold at the current metrics (`maxTexturePixels`). Past that bound the view
    /// shows fewer columns or rows than the grid in force, which looks like clipping.
    private(set) var shownGrid: TerminalSize?
    /// The size in points that shows `shownGrid` at the current metrics, which the
    /// pane's container applies, and the view applies to itself while no container
    /// holds it (`applyImposedSizeOffDisplay`). Nil with no grid imposed, or with
    /// metrics not known yet.
    private(set) var imposedSize: CGSize?

    /// Metal's largest 2D texture side, in pixels. Measured on this machine's M4:
    /// a 16384 wide texture is made, a 16385 wide one is refused by validation.
    /// libghostty renders the surface's whole pixel size into one such texture.
    static let maxTexturePixels = 16_384

    /// The configuration's background colour and opacity, set by the host.
    var configuredBackground: NSColor = .black {
        didSet { if configuredBackground != oldValue { container?.surfaceSizingDidChange() } }
    }
    var backgroundOpacity: Double = 1 {
        didSet { if backgroundOpacity != oldValue { container?.surfaceSizingDidChange() } }
    }
    /// The background a program set (`OSC 11`, or the configured colour again
    /// after a reset), as libghostty reported it with a colour change action.
    var programBackground: NSColor? {
        didSet { if programBackground != oldValue { container?.surfaceSizingDidChange() } }
    }
    /// The colour the terminal draws its background in, for the margin the pane's
    /// container draws around a smaller grid.
    var marginColor: NSColor {
        Self.marginColor(configured: configuredBackground, program: programBackground,
                         opacity: backgroundOpacity)
    }

    /// The program's background when it set one, else the configured one, at the
    /// configured `background-opacity` (which libghostty applies to both).
    static func marginColor(configured: NSColor, program: NSColor?, opacity: Double) -> NSColor {
        (program ?? configured).withAlphaComponent(CGFloat(min(1, max(0, opacity))))
    }
    private var container: SurfaceContainerView? { superview as? SurfaceContainerView }

    /// The composition an input method is building, if any.
    private var marked = GhosttyMarkedText()
    /// Non-nil only while `keyDown` is inside `interpretKeyEvents`, which is how
    /// `insertText` tells committed text apart from text arriving out of band
    /// (dictation, a Services menu item) that has to be sent straight through.
    private var collectedText: [String]?
    /// The editing command AppKit resolved the key in flight into, if it did.
    private var interpretedCommand: Selector?

    /// The surface this view renders, for the host's own runtime callbacks.
    /// Borrowed, and nil once the host has freed it.
    var surfaceHandle: ghostty_surface_t? { surface }

    /// - Parameter host: nil only in a test, for a view with no surface behind it.
    init(frame: NSRect, host: GhosttySurfaceHost?, id: String) {
        self.host = host
        self.id = id
        super.init(frame: frame)
        // No `CAMetalLayer`. libghostty attaches its own `IOSurfaceLayer` on the
        // first frame and a host supplied layer is left detached, so writing
        // metrics to one would do nothing at all.
        wantsLayer = true
        // Without this AppKit rejects a file drag before it reaches the view, so
        // dropping a file onto the pane does nothing. See "Drag and drop" below.
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func adopt(surface: ghostty_surface_t) {
        self.surface = surface
        // Right away, not on the first layout: a surface whose metrics were never
        // sent renders nothing even once it has a size. Reporting is suppressed,
        // because `adopt` runs inside `createSurface` and the grid report must not.
        synchronizeMetrics(reportGrid: false)
        requestRedraw()
        // The first grid report is deliberately one main queue turn late, so it
        // lands after `createSurface` has returned to its caller.
        //
        // The caller is not finished creating the terminal while it is still inside
        // `createSurface`, and a handler that resolves the session through its own
        // registry would find nothing yet. Neither report resizes anything any more
        // (decision P4), but the first metrics report is what lets the pane's grid
        // compute the grid that fits the pane, and a report from inside `adopt`
        // latched on `lastGrid` and `lastMetrics` would never come again.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reportInitialGrid() }
        }
    }

    /// Reports the grid as it stands, changed or not. Only the first report goes
    /// through here: it has to arrive even though nothing has moved since the
    /// surface was created.
    private func reportInitialGrid() {
        // The metrics too, held back from `adopt` for the same reason, and once.
        if lastMetrics == nil { noteMetrics(report: true) }
        // Skipped if a layout beat this turn to it, so the caller sees one event
        // rather than two identical ones.
        guard lastGrid == nil, let grid = currentGrid() else { return }
        lastGrid = grid
        host?.report(grid: grid, for: id)
    }

    /// Takes the surface's metrics afresh: the cell size libghostty derived, the
    /// padding (configured, unless this surface's own reports rule it out; see
    /// `PaddingWindow`), and the scale it was just given. Nil when libghostty reports
    /// no cell, which does not happen after `adopt`'s first synchronisation, so in
    /// practice metrics are known from `createSurface` on.
    private func takeMetrics(scale: Double) {
        guard let surface, let host else { metrics = nil; return }
        let size = ghostty_surface_size(surface)
        let cellWidth = Int(size.cell_width_px), cellHeight = Int(size.cell_height_px)
        guard cellWidth > 0, cellHeight > 0 else { metrics = nil; return }
        let key = [Double(cellWidth), Double(cellHeight), scale, Double(host.configGeneration)]
        corrections.metricsTaken(key: key)
        if key != paddingWindowsKey {
            paddingWindowsKey = key
            paddingWindows = (PaddingWindow(), PaddingWindow())
            reportedPaddingMismatch = false
        }
        paddingWindows.x.observe(pixels: Int(size.width_px), cells: Int(size.columns), cell: cellWidth)
        paddingWindows.y.observe(pixels: Int(size.height_px), cells: Int(size.rows), cell: cellHeight)
        let configured = host.padding.pixels(scale: scale)
        let paddingX = paddingWindows.x.padding(configured: configured.x)
        let paddingY = paddingWindows.y.padding(configured: configured.y)
        if paddingX != configured.x || paddingY != configured.y, !reportedPaddingMismatch {
            reportedPaddingMismatch = true
            GhosttySurfaceHost.log.fault(
                "configured padding \(configured.x)x\(configured.y)px does not fit surface \(self.id, privacy: .public); using \(paddingX)x\(paddingY)px")
        }
        metrics = SurfaceMetrics(cellWidth: cellWidth, cellHeight: cellHeight,
                                 paddingX: paddingX, paddingY: paddingY, scale: scale)
    }

    /// The grid that fits the pane this surface is shown in, at its metrics: what the
    /// pane claims. Nil while the surface is not on display (not in a pane in a
    /// window, or in one with no size yet) or its metrics are not known.
    var ownGrid: TerminalSize? { ownGrid(at: metrics) }

    /// The same at these metrics. The CONTAINER's bounds, never this view's own: an
    /// imposed size gives this view another frame, and that must not feed back into
    /// the grid the pane claims.
    func ownGrid(at metrics: SurfaceMetrics?) -> TerminalSize? {
        guard window != nil, let pane = superview as? SurfaceContainerView,
              pane.bounds.width > 0, pane.bounds.height > 0, let metrics else { return nil }
        return metrics.grid(fitting: Double(pane.bounds.width), Double(pane.bounds.height))
    }

    /// Called on every key, click, paste and drop; the host points it at the pane's
    /// grid (`OwnPaneGrid.userActed`).
    var onUserAction: (@MainActor () -> Void)?

    /// The pane around this surface changed size.
    func paneSizeDidChange() {
        host?.paneChanged(for: id)
    }

    /// `grid` held to the protocol's range and, at these metrics, to what the
    /// renderer's texture can hold.
    static func shownGrid(for grid: TerminalSize, metrics: SurfaceMetrics?) -> TerminalSize {
        let range = TerminalBridge.claimRange
        let held = TerminalSize(cols: min(max(grid.cols, range.lowerBound), range.upperBound),
                                rows: min(max(grid.rows, range.lowerBound), range.upperBound))
        return metrics?.clamped(held, maxPixels: maxTexturePixels) ?? held
    }

    /// Recomputes the imposed size from the metrics as they stand and, when it
    /// moved, asks the container to apply it, or applies it itself with no container.
    private func refreshImposedSize() {
        shownGrid = imposedGrid.map { Self.shownGrid(for: $0, metrics: metrics) }
        if let imposedGrid, let shownGrid, shownGrid != imposedGrid, !reportedClamp {
            reportedClamp = true
            GhosttySurfaceHost.log.error(
                "grid \(imposedGrid.cols)x\(imposedGrid.rows) imposed on \(self.id, privacy: .public) is shown as \(shownGrid.cols)x\(shownGrid.rows)")
        }
        let size = shownGrid.flatMap { grid in
            metrics.map { metrics -> CGSize in
                let points = metrics.viewSize(for: grid)
                return CGSize(width: points.width, height: points.height)
            }
        }
        guard size != imposedSize else { return }
        imposedSize = size
        container?.surfaceSizingDidChange()
        applyImposedSizeOffDisplay()
    }

    /// Set while `applyImposedSizeOffDisplay` sizes the view, whose own
    /// `setFrameSize` comes back here through `synchronizeMetrics`.
    private var applyingOffDisplaySize = false

    /// A view held by no container is given the imposed size directly, so the
    /// surface's grid follows the grid in force while the terminal is not on display:
    /// the pty and the model are at that grid, and the surface, which answers the
    /// terminal's queries and keeps its history, has to lay the child's output out
    /// for the same one. Outside the view hierarchy the view is frame based; `hold`
    /// replaces that with the container's constraints when it is shown, which then
    /// find it at the size they ask for. With no grid imposed the frame is left as
    /// it is.
    ///
    /// The size in points comes from `metrics`, taken at the scale the surface last
    /// rendered at, which is the scale `synchronizeMetrics` uses for a view with no
    /// window, so the pixel size it sets is the one the size was computed for. A new
    /// size can move the metrics (the padding bounds narrow), and with them the
    /// imposed size, so the size is applied again until it holds, as often as the
    /// closed loop may correct it.
    private func applyImposedSizeOffDisplay() {
        guard superview == nil, !applyingOffDisplaySize else { return }
        applyingOffDisplaySize = true
        defer { applyingOffDisplaySize = false }
        for _ in 0...Self.maxCorrections {
            guard let imposedSize, frame.size != imposedSize else { return }
            setFrameSize(imposedSize)
        }
    }

    /// Hands the view metrics as `synchronizeMetrics` would take them, for a test of
    /// a view with no surface behind it (`host` nil), which takes none of its own.
    func useMetricsForTesting(_ metrics: SurfaceMetrics) {
        self.metrics = metrics
        noteMetrics(report: false)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Taken out of a container before its constraints gave the view the
        // imposed size it asked for: it gets that size now.
        applyImposedSizeOffDisplay()
    }

    /// The closed loop: with a grid imposed and the view at its size, the surface
    /// must show exactly that grid. When it does not, the padding in use was wrong;
    /// this observation has already narrowed the padding bounds, so sizing again
    /// from the new metrics corrects it. At most `maxCorrections` times per grid and
    /// per metrics key.
    private func checkImposedGrid() {
        guard let shownGrid, let imposedSize, bounds.size == imposedSize,
              let grid = currentGrid(), grid != shownGrid else { return }
        GhosttySurfaceHost.log.fault(
            "surface \(self.id, privacy: .public) shows \(grid.cols)x\(grid.rows) at the size of \(shownGrid.cols)x\(shownGrid.rows)")
        guard corrections.take() else { return }
        refreshImposedSize()
    }

    /// The metrics may have moved: the imposed size follows them, and a change is
    /// reported unless this runs inside `createSurface`.
    private func noteMetrics(report: Bool) {
        refreshImposedSize()
        guard report, let metrics, metrics != lastMetrics else { return }
        lastMetrics = metrics
        host?.reportMetrics(for: id)
    }

    func detachSurface() {
        surface = nil
    }

    // MARK: Drawing

    /// Coalesces every redraw request onto one main queue turn. Two sources feed
    /// it: `wakeup_cb` and `GHOSTTY_ACTION_RENDER`.
    func requestRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            redrawScheduled = false
            drawNow()
        }
    }

    private func drawNow() {
        guard let surface, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
    }

    // MARK: Metrics

    /// The grid libghostty derived from the current size, or nil before it has one.
    private func currentGrid() -> TerminalSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return TerminalSize(cols: Int(size.columns), rows: Int(size.rows))
    }

    /// Content scale first, then pixel size, then re-read the grid.
    ///
    /// The order matters: libghostty derives the cell grid from size divided by
    /// scale, so a new size sent against a stale scale gives a grid that is wrong
    /// for one frame, which shows up as a jump. `ghostty_surface_set_size` takes
    /// pixels, not points.
    ///
    /// - Parameter reportGrid: false only from `adopt`, which runs while
    ///   `createSurface` is still on its caller's stack. See `adopt`.
    func synchronizeMetrics(reportGrid: Bool = true) {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        // A surface with no window keeps the scale it last rendered at: a hidden
        // terminal synchronised by a configuration reload must not move to the main
        // screen's scale (another grid, on a machine with mixed displays).
        let scale = window.map { Double($0.backingScaleFactor) }
            ?? renderScale ?? Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        renderScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface,
                                 UInt32((bounds.width * scale).rounded(.down)),
                                 UInt32((bounds.height * scale).rounded(.down)))
        // The layer libghostty attached, never a cached one of our own.
        layer?.contentsScale = scale
        takeMetrics(scale: scale)

        // Every grid change is reported. A report, not a claim: nothing resizes the
        // pty from it (decision P4). The pane claims from the grid that fits it,
        // through `OwnPaneGrid`.
        if reportGrid, let grid = currentGrid(), grid != lastGrid {
            lastGrid = grid
            host?.report(grid: grid, for: id)
        }
        noteMetrics(report: reportGrid)
        checkImposedGrid()
        requestRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeMetrics()
    }

    override func layout() {
        super.layout()
        synchronizeMetrics()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeMetrics()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        if window == nil {
            // Detached. The surface, its child and its scrollback all stay alive;
            // only the frames stop.
            ghostty_surface_set_occlusion(surface, false)
            ghostty_surface_set_focus(surface, false)
        } else {
            ghostty_surface_set_occlusion(surface, true)
            // After the move, because the new window can be on a display with a
            // different backing scale factor.
            synchronizeMetrics()
            requestRedraw()
        }
        // On or off display: the pane's grid claims nothing while off it.
        host?.paneChanged(for: id)
    }

    // MARK: Focus and input

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return resigned
    }

    /// Every key goes through AppKit's input context first.
    ///
    /// It has to, or no input method works: `interpretKeyEvents` is what lets one
    /// compose, and it answers in one of three ways. Committed text arrives through
    /// `insertText` and is forwarded as the key's text. Text still being composed
    /// arrives through `setMarkedText` and becomes libghostty's preedit. A key with
    /// no text at all is resolved into an editing command through `doCommand(by:)`,
    /// and a terminal needs the hardware key rather than the command, so the text
    /// is dropped and libghostty encodes from the keycode.
    ///
    /// That last case is what makes return, tab, backspace, escape and the arrows
    /// work: AppKit turns each into `insertNewline:`, `insertTab:` and so on, and
    /// libghostty knows what byte each key means in the mode the terminal is in.
    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        // The user is typing into the terminal they can see, which answers any bell
        // it rang while the app was in the background. Reported before the key is
        // encoded, and unconditionally: the store drops the flag once and no-ops
        // after, so gating on which key it was would buy nothing.
        host?.userTyped(in: id)
        // And takes the grid back if another viewer had it.
        onUserAction?()
        let action: ghostty_input_action_e =
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let composingBefore = marked.isComposing
        // The event as libghostty's own key translation wants it seen, which is
        // what makes a configured `macos-option-as-alt` produce "f" rather than
        // the "ƒ" macOS would compose for option plus f.
        let translated = translatedEvent(for: event)

        collectedText = []
        interpretedCommand = nil
        interpretKeyEvents([translated])
        let collected = collectedText
        collectedText = nil

        // The preedit reaches libghostty before the key does, or what it draws is
        // one keystroke behind what the input method has. `setMarkedText` skips
        // this while collecting for exactly that reason.
        if marked.isComposing || composingBefore { syncPreedit() }

        if let collected, !collected.isEmpty {
            for text in collected {
                send(event: event, translated: translated, action: action,
                     text: text, composing: false)
            }
            return
        }

        let interpreted = interpretedCommand != nil
        interpretedCommand = nil
        send(event: event, translated: translated, action: action,
             text: interpreted ? nil : Self.text(for: translated),
             composing: marked.isComposing || composingBefore)
    }

    override func keyUp(with event: NSEvent) {
        send(event: event, translated: event, action: GHOSTTY_ACTION_RELEASE,
             text: nil, composing: false)
    }

    /// Forwarded too, or libghostty never learns a modifier was released.
    ///
    /// The action is derived from whether the modifier is still held, rather than
    /// always claiming a press as this once did: a shell that reads modifier state
    /// otherwise believes control is held forever after the first time it was
    /// tapped. Left and right are not told apart, so releasing one shift while the
    /// other is held still reports a press, which is the honest reading of "shift
    /// is down" and only matters to a keybinding that names a side.
    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        // Left alone during composition: an input method uses modifiers to pick
        // candidates and the terminal must not see them as input.
        guard !marked.isComposing else { return }
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        let mods = Self.mods(from: event.modifierFlags)
        var input = ghostty_input_key_s()
        input.action = (mods.rawValue & mod) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        input.keycode = UInt32(event.keyCode)
        input.mods = mods
        input.consumed_mods = ghostty_input_mods_e(0)
        input.text = nil
        _ = ghostty_surface_key(surface, input)
    }

    /// Two combinations AppKit consumes before `keyDown` ever sees them, both of
    /// which send a byte in every other terminal: control plus return, and control
    /// plus slash (0x1F, the undo key in vim and emacs).
    ///
    /// Control plus slash is rewritten to control plus underscore before being
    /// forwarded, which is defensive parity with the pinned reference and upstream
    /// Ghostty rather than a repair. Measured on libghostty 1.3.2, both forms a macOS
    /// layout can report produced 0x1F with and without the rewrite, because the byte
    /// is derived from `unshifted_codepoint` (0x2F for this key, filled in by `send`)
    /// and not from the text. Kept so the behaviour does not depend on that
    /// undocumented path.
    ///
    /// Deliberately narrow. Command based shortcuts are left to the app's menus,
    /// because this window is a workspace manager first and its menu items are not
    /// the terminal's to swallow.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, surface != nil,
              window?.firstResponder === self,
              event.modifierFlags.contains(.control),
              let characters = event.charactersIgnoringModifiers else { return false }
        switch characters {
        case "\r":
            keyDown(with: event)
            return true
        case "/" where event.modifierFlags.isDisjoint(with: [.shift, .command, .option]):
            // The original event when AppKit refuses to build the substitute, since
            // that is the form measured to work anyway.
            keyDown(with: Self.substituting("_", in: event) ?? event)
            return true
        default:
            return false
        }
    }

    /// The same key event with different characters, or nil when AppKit refuses to
    /// build one.
    static func substituting(_ characters: String, in event: NSEvent) -> NSEvent? {
        NSEvent.keyEvent(with: event.type,
                         location: event.locationInWindow,
                         modifierFlags: event.modifierFlags,
                         timestamp: event.timestamp,
                         windowNumber: event.windowNumber,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: event.isARepeat,
                         keyCode: event.keyCode)
    }

    /// Records the command rather than performing it.
    ///
    /// AppKit resolves keys with no text into editing commands, and a terminal
    /// wants the key: `keyDown` reads this back and sends the hardware key with no
    /// text so libghostty encodes it. Not calling super also silences the beep
    /// AppKit makes for the commands an `NSView` does not implement.
    override func doCommand(by selector: Selector) {
        interpretedCommand = selector
    }

    /// The event with the modifiers libghostty's own key translation asks for.
    ///
    /// libghostty is configurable about which modifiers take part in producing
    /// text, and `ghostty_surface_key_translation_mods` is how it says so. The
    /// event is rebuilt only when the answer differs from what macOS reported, so
    /// a default configuration goes through untouched.
    private func translatedEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translated = ghostty_surface_key_translation_mods(
            surface, Self.mods(from: event.modifierFlags))
        var flags = event.modifierFlags
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
                            (.control, GHOSTTY_MODS_CTRL),
                            (.option, GHOSTTY_MODS_ALT),
                            (.command, GHOSTTY_MODS_SUPER)] {
            if translated.rawValue & mod.rawValue != 0 { flags.insert(flag) } else { flags.remove(flag) }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(with: event.type,
                                location: event.locationInWindow,
                                modifierFlags: flags,
                                timestamp: event.timestamp,
                                windowNumber: event.windowNumber,
                                context: nil,
                                characters: event.characters(byApplyingModifiers: flags) ?? "",
                                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                isARepeat: event.isARepeat,
                                keyCode: event.keyCode) ?? event
    }

    /// - Parameter event: the key as macOS reported it, which is what the keycode
    ///   and the real modifier state come from.
    /// - Parameter translated: the same key as libghostty's translation wants it,
    ///   which is what the consumed modifiers come from.
    private func send(event: NSEvent, translated: NSEvent, action: ghostty_input_action_e,
                      text: String?, composing: Bool) {
        guard let surface else { return }
        var input = ghostty_input_key_s()
        input.action = action
        input.keycode = UInt32(event.keyCode)
        input.mods = Self.mods(from: event.modifierFlags)
        // Control and command stay unconsumed, or keybindings never match.
        var consumed = translated.modifierFlags
        consumed.remove(.control)
        consumed.remove(.command)
        input.consumed_mods = Self.mods(from: consumed)
        input.composing = composing
        // The bare key, ignoring every modifier. libghostty needs it to encode
        // ctrl plus a letter as a legacy control byte; given only the already
        // controlled codepoint it falls back to the Kitty `CSI <code>;<mods>u`
        // form, which a plain shell prints literally instead of interrupting.
        var unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
        if unshifted == nil || unshifted!.value < 0x20 {
            if let bare = event.charactersIgnoringModifiers?.unicodeScalars.first, bare.value >= 0x20 {
                unshifted = bare
            }
        }
        if let unshifted, !(0xF700 ... 0xF8FF).contains(unshifted.value) {
            input.unshifted_codepoint = unshifted.value
        }
        guard let text, !text.isEmpty else {
            input.text = nil
            _ = ghostty_surface_key(surface, input)
            return
        }
        text.withCString { pointer in
            input.text = pointer
            _ = ghostty_surface_key(surface, input)
        }
    }

    /// Hands libghostty the composition as it stands, or clears it.
    fileprivate func syncPreedit() {
        guard let surface else { return }
        let text = marked.text ?? ""
        text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
    }

    /// Text that did not come from a key press: dictation, a Services item, a
    /// drag. Sent straight to the surface, which is the only path it has.
    fileprivate func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        onUserAction?()
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    // MARK: Drag and drop

    /// A dropped file's path, quoted so a shell reads it as one literal argument.
    ///
    /// Single quoted, with each embedded single quote closed and re-opened around
    /// an escaped one (`'\''`), which is the only byte a single quoted string
    /// cannot otherwise contain. Spaces, double quotes and newlines then stay
    /// inside the quotes, so a filename with any of them lands as one argument and
    /// cannot run as shell input.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The text a drop of these files inserts: each path shell quoted, joined by a
    /// single space, and with no trailing newline so nothing is submitted before
    /// the user presses return.
    static func insertionText(forDroppedFiles urls: [URL]) -> String {
        urls.map { shellQuoted($0.path) }.joined(separator: " ")
    }

    /// The file URLs a pasteboard carries, in drop order, or empty for a drag that
    /// is not files (a text selection, a colour). Restricted to file URLs so a
    /// dragged web link does not read as a path.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    /// Whether a pasteboard carries file URLs, without materialising them. Called
    /// from `draggingEntered` to decide whether to accept the drag, so it uses the
    /// cheap `canReadObject` probe rather than reading the URLs to answer.
    static func canDropFiles(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true])
    }

    /// `.copy` while a file drag is over the pane, which is what draws the drop
    /// highlight and the plus badge; nothing for any other drag.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.canDropFiles(on: sender.draggingPasteboard) ? .copy : []
    }

    /// Reads the dropped files, takes focus so the paths land where the user is
    /// working, and sends them the same way pasted text is sent. Plain text, not
    /// the paste binding: the paths are one line with no newline, `shellQuoted`
    /// already makes them safe, and going through the binding would raise the
    /// unsafe paste alert for nothing.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        window?.makeFirstResponder(self)
        sendText(Self.insertionText(forDroppedFiles: urls))
        return true
    }

    // MARK: Mouse

    /// A point in this view's coordinates, in the space libghostty wants: origin
    /// top left, and in points rather than pixels.
    ///
    /// Points, not pixels, unlike `ghostty_surface_set_size`. libghostty scales a
    /// mouse position by the content scale itself, so multiplying here would put
    /// every click at twice its column on a Retina display.
    static func surfacePoint(of viewPoint: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: viewPoint.x, y: bounds.height - viewPoint.y)
    }

    /// Packs a scroll event into libghostty's `ghostty_input_scroll_mods_t`: bit 0
    /// says the deltas are precise (a trackpad rather than a wheel), and the bits
    /// above it carry the momentum phase.
    ///
    /// - Parameter momentum: the raw value of a `ghostty_input_mouse_momentum_e`.
    ///   Passed as an integer so the packing itself can be asserted without
    ///   libghostty present.
    static func scrollMods(precision: Bool, momentum: Int32) -> Int32 {
        (precision ? 1 : 0) | (momentum << 1)
    }

    private static func momentum(of phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        if phase.contains(.began) { return GHOSTTY_MOUSE_MOMENTUM_BEGAN }
        if phase.contains(.stationary) { return GHOSTTY_MOUSE_MOMENTUM_STATIONARY }
        if phase.contains(.changed) { return GHOSTTY_MOUSE_MOMENTUM_CHANGED }
        if phase.contains(.ended) { return GHOSTTY_MOUSE_MOMENTUM_ENDED }
        if phase.contains(.cancelled) { return GHOSTTY_MOUSE_MOMENTUM_CANCELLED }
        if phase.contains(.mayBegin) { return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN }
        return GHOSTTY_MOUSE_MOMENTUM_NONE
    }

    /// Tells libghostty where the pointer is. Sent before every button and every
    /// drag, because libghostty resolves a button against the last position it was
    /// given: a press sent before the move it belongs to lands on the old cell.
    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = Self.surfacePoint(of: convert(event.locationInWindow, from: nil), in: bounds)
        ghostty_surface_mouse_pos(surface, point.x, point.y, Self.mods(from: event.modifierFlags))
    }

    private func sendMouseButton(_ event: NSEvent,
                                 _ state: ghostty_input_mouse_state_e,
                                 _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button,
                                        Self.mods(from: event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a terminal is how a user says "type here", and the pane cannot
        // know which of several surfaces that is.
        window?.makeFirstResponder(self)
        onUserAction?()
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        onUserAction?()
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        onUserAction?()
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY,
            Self.scrollMods(precision: event.hasPreciseScrollingDeltas,
                            momentum: Int32(Self.momentum(of: event.momentumPhase).rawValue)))
    }

    /// Rebuilt on every layout, because the tracking area is what makes
    /// `mouseMoved` arrive at all and a stale one covers the old frame. Only while
    /// the window is key: a program tracking the pointer should not be fed moves
    /// the user made in another app's window.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    /// An I-beam over the whole surface. libghostty asks for other shapes through
    /// `GHOSTTY_ACTION_MOUSE_SHAPE`, which is not handled, so a full screen program
    /// that wants an arrow gets a text cursor.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: Selection and clipboard

    /// Copy, from the standard Edit menu and its shortcut. Reads libghostty's own
    /// selection, which the mouse handlers above are what create.
    @objc func copy(_ sender: Any?) {
        guard let surface, ghostty_surface_has_selection(surface) else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return }
        let string = String(decoding: UnsafeRawBufferPointer(start: pointer,
                                                            count: Int(text.text_len)),
                            as: UTF8.self)
        let pasteboard = host?.pasteboard ?? .general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Paste, through libghostty's own binding rather than by writing the text.
    ///
    /// The binding is what wraps the text in bracketed paste when the program
    /// asked for it, and what runs the unsafe paste check. It reaches the host's
    /// `read_clipboard_cb`, which is why that callback has to be real.
    @objc func paste(_ sender: Any?) {
        onUserAction?()
        perform(binding: "paste_from_clipboard")
    }

    @objc override func selectAll(_ sender: Any?) { perform(binding: "select_all") }

    private func perform(binding: String) {
        guard let surface else { return }
        _ = binding.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(binding.utf8.count))
        }
    }

    /// The text to hand libghostty for a key event, or nil to let it encode the
    /// key from the keycode and modifiers.
    ///
    /// Both filters below are load bearing and both were found from a visible
    /// bug rather than from the header.
    ///
    /// - macOS reports arrows and function keys as Private Use Area scalars.
    ///   Forwarded as text they print garbage into the terminal, and vim receives
    ///   the scalar as literal input.
    /// - With control held, `characters` is already the control byte. libghostty
    ///   must be given the printable key ("c", not U+0003): handed the control
    ///   byte it emits `CSI 3;5u`, which the spike watched a shell print
    ///   literally while the `sleep 60` it was meant to interrupt kept running.
    static func text(for event: NSEvent) -> String? {
        guard let characters = event.characters, let first = characters.unicodeScalars.first else {
            return nil
        }
        if (0xF700 ... 0xF8FF).contains(first.value) { return nil }
        guard first.value < 0x20 else { return characters }
        var flags = event.modifierFlags
        flags.remove(.control)
        guard let printable = event.characters(byApplyingModifiers: flags),
              let scalar = printable.unicodeScalars.first, scalar.value >= 0x20 else {
            // A synthesized event cannot always be re-translated; the unmodified
            // characters are the letter for ctrl plus a letter, which is what is
            // wanted here.
            return event.charactersIgnoringModifiers
        }
        return printable
    }

    static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }
}

// MARK: - Input methods

/// What an input method needs to compose into a terminal.
///
/// A terminal has no editable document, so almost every method here answers about
/// the composition alone: position zero is the start of the preedit, not of a line.
/// The one thing AppKit really needs from the terminal is
/// `firstRect(forCharacterRange:)`, which is where the candidate window is drawn,
/// and libghostty answers that from the cursor's cell.
/// `@preconcurrency` because `NSTextInputClient` is not annotated for the main
/// actor even though AppKit only ever calls it from there: every one of these
/// arrives from the first responder's own input context, on the main thread.
extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    /// Text the input method committed.
    ///
    /// Inside a `keyDown` it is collected and sent as that key's text, so
    /// libghostty can still apply its keybindings and encoding to it. Out of band
    /// (dictation, a Services item) there is no key to attach it to, so it goes
    /// straight to the surface as text.
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.text(fromInputMethod: string) else { return }
        // The composition is finished by definition once its result is committed.
        unmarkText()
        if collectedText != nil {
            collectedText?.append(text)
        } else {
            sendText(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let text = Self.text(fromInputMethod: string) else { return }
        marked.set(text, selection: selectedRange)
        // Not while `keyDown` is collecting: it syncs once, after
        // `interpretKeyEvents` returns, so the preedit and the key arrive in order.
        if collectedText == nil { syncPreedit() }
    }

    func unmarkText() {
        guard marked.isComposing else { return }
        marked.clear()
        syncPreedit()
    }

    func selectedRange() -> NSRange { marked.selectedRange }
    func markedRange() -> NSRange { marked.markedRange }
    func hasMarkedText() -> Bool { marked.isComposing }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        guard marked.isComposing else { return nil }
        let clamped = marked.clamped(range)
        actualRange?.pointee = clamped
        return marked.substring(in: clamped).map { NSAttributedString(string: $0) }
    }

    /// None. The preedit is drawn by libghostty inside the grid, so there are no
    /// attributes for AppKit to apply to it.
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the candidate window goes: the cursor's cell, in screen coordinates.
    /// libghostty reports the cell with its origin at the top left, which is the
    /// opposite of an `NSView`'s, hence the flip.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = surfaceHandle else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: bounds.height - y - height, width: width, height: height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// Unanswerable, and saying so is correct: this maps a screen point onto a
    /// document index, and there is no document behind a terminal's grid.
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// An input method hands over either a plain or an attributed string, and the
    /// attributes are never ours to use.
    private static func text(fromInputMethod string: Any) -> String? {
        if let attributed = string as? NSAttributedString { return attributed.string }
        return string as? String
    }
}
