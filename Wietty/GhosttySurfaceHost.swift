import AppKit
import Foundation
import GhosttyKit
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
/// - **`ghostty_app_tick` runs only in response to `wakeup_cb`, on the main
///   thread.** There is no polling interval to choose. Every other call in this
///   API is main thread only.
/// - **A view holding a live surface survives re-parenting.** Removed from its
///   superview and added back, and moved into a brand new `NSWindow`, with the
///   shell still running and the scrollback intact. The whole pane design rests on
///   that: the surface is never recreated, because recreating it is what would
///   lose the scrollback.
@MainActor
final class GhosttySurfaceHost: TerminalSurfaceHosting {
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

    /// The label the app gave each surface. libghostty has no title setter of any
    /// kind, so this is the host's own record rather than something pushed into
    /// the terminal; `GHOSTTY_ACTION_SET_TITLE` overwrites it when the shell sets
    /// one.
    private var titles: [String: String] = [:]

    var onTitle: (@MainActor (String, String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    var onResized: (@MainActor (String, TerminalSize) -> Void)?
    var onCloseRequested: (@MainActor (String) -> Void)?

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

    init() throws {
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
        runtime.confirm_read_clipboard_cb = { userdata, string, request, _ in
            GhosttySurfaceHost.confirmReadClipboard(userdata: userdata,
                                                    string: string,
                                                    request: request)
        }
        runtime.write_clipboard_cb = { _, _, contents, count, _ in
            guard count > 0, let data = contents?.pointee.data else { return }
            let string = String(cString: data)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            GhosttySurfaceHost.closeSurface(userdata: userdata)
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            self.config = nil
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
    private static func buildConfig(overlay: URL? = GhosttyOverrideFile.defaultURL) -> ghostty_config_t? {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        if let overlay { ghostty_config_load_file(config, overlay.path) }
        ghostty_config_finalize(config)
        return config
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

    func reloadConfig() {
        guard let app else { return }
        let rebuilt = Self.buildConfig()
        // The app first, then every surface. libghostty copies what it needs out of
        // the config, so the old one can be freed once both have been handed the new
        // one, and freeing it before the surfaces are updated would leave them
        // reading it.
        ghostty_app_update_config(app, rebuilt)
        for surface in surfaces.values {
            ghostty_surface_update_config(surface.handle, rebuilt)
        }
        if let previous = config { ghostty_config_free(previous) }
        config = rebuilt
    }

    // MARK: - Surfaces

    func createSurface(id: String, command: String, directory: URL, title: String?) throws {
        guard let app else { throw SurfaceHostError.surfaceFailed }
        guard surfaces[id] == nil else { throw SurfaceHostError.surfaceFailed }

        // A size, not zero: a surface created against a zero sized view stays
        // blank even after it is laid out, unless the metrics are sent again. The
        // pane's constraints replace this on the first layout pass.
        let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                      host: self,
                                      id: id)

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
        surfaces[id] = Surface(view: view, handle: handle)
        if let title { setTitle(title, for: id) }
        view.adopt(surface: handle)
    }

    func destroySurface(id: String) {
        guard let surface = surfaces.removeValue(forKey: id) else { return }
        titles[id] = nil
        // The view's pointer is cleared before the free, because a view can still
        // be laid out on its way out of the hierarchy and every one of its calls
        // would then be a use after free.
        surface.view.detachSurface()
        surface.view.removeFromSuperview()
        ghostty_surface_free(surface.handle)
    }

    func view(id: String) -> NSView? { surfaces[id]?.view }

    func size(id: String) -> TerminalSize? {
        guard let surface = surfaces[id] else { return nil }
        let size = ghostty_surface_size(surface.handle)
        guard size.columns > 0, size.rows > 0 else { return nil }
        return TerminalSize(cols: Int(size.columns), rows: Int(size.rows))
    }

    /// Whether a read of `maxLines` rows has to reach past the grid into
    /// scrollback.
    ///
    /// Strictly greater, and the boundary is the whole point: `maxLines` exactly
    /// equal to the grid's height is the visible screen, which the cheap viewport
    /// read answers in full. It is also the case that runs most often by far,
    /// because `GhosttyService.recordSnapshot` asks for precisely the grid's own row
    /// count on every refresh. Reading this as `>=` sent that call down the whole
    /// screen path, so every recorded snapshot paid roughly 34 ms of main actor time
    /// instead of 0.14 ms.
    ///
    /// Extracted from `snapshot` so the boundary can be asserted without a live
    /// surface, a Metal device, or a deep scrollback to measure against.
    nonisolated static func readsScrollback(maxLines: Int, gridRows: Int) -> Bool {
        maxLines > gridRows
    }

    /// The last `maxLines` rows of the surface's screen, reaching into scrollback
    /// when more than the visible grid is asked for.
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
    /// boundary included; see `readsScrollback`. A caller asking for more than the
    /// grid on every resize will pay the 34 ms.
    func snapshot(id: String, maxLines: Int) -> ScreenSnapshot? {
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
            return ScreenSnapshot(rows: [], cols: Int(size.columns))
        }
        let joined = String(decoding: UnsafeRawBufferPointer(start: pointer,
                                                             count: Int(text.text_len)),
                            as: UTF8.self)
        let rows = joined.components(separatedBy: "\n")
        return ScreenSnapshot(rows: rows.count > maxLines ? Array(rows.suffix(maxLines)) : rows,
                              cols: Int(size.columns))
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
    /// libghostty asked for it through `wakeup_cb`.
    private func tickAndRedrawAll() {
        guard let app else { return }
        ghostty_app_tick(app)
        for surface in surfaces.values { surface.view.requestRedraw() }
    }

    // MARK: - Actions

    /// What a libghostty action means to this host. The payload is copied out of
    /// the C structure before the hop to the main queue, because the pointers in
    /// it are only valid for the duration of the callback.
    private enum SurfaceEvent: Sendable {
        case render
        case bell
        case notification(title: String, body: String)
        case title(String)
        case cellSize
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
        case GHOSTTY_ACTION_SET_TITLE:
            guard let pointer = action.action.set_title.title else { return false }
            event = .title(String(cString: pointer))
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Deliberately unhandled, and false rather than true so libghostty
            // knows the host did not show anything.
            //
            // libghostty means "the process this surface was running has ended,
            // show the user". On this substrate that process is `wietty-pty`,
            // which ends when its socket closes: it is downstream of the terminal
            // ending rather than the cause of it, and it also fires when the app
            // itself tears a terminal down. The row's own state comes from the
            // relay's EOF instead, through `GhosttyService.reap` and the monitor,
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

    private func apply(_ event: SurfaceEvent, to id: String) {
        guard let surface = surfaces[id] else { return }
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
        }
    }

    /// Called by a view whose grid changed, so the pty behind it can follow.
    fileprivate func report(grid: TerminalSize, for id: String) {
        guard surfaces[id] != nil else { return }
        onResized?(id, grid)
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
    /// which on this substrate is the helper losing its socket, and the last
    /// screen a command left behind is what the user wants to read. The handler's
    /// job is to retire the terminal, and `close`/`closeAll` remain the only
    /// things that destroy a surface.
    private func requestClose(_ id: String) {
        guard surfaces[id] != nil else { return }
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
    private nonisolated static func readClipboard(userdata: UnsafeMutableRawPointer?,
                                                  request: UnsafeMutableRawPointer?) -> Bool {
        guard Thread.isMainThread, let userdata, let request else { return false }
        let view = RawPointerBox(pointer: userdata)
        let pending = RawPointerBox(pointer: request)
        return MainActor.assumeIsolated {
            let surfaceView = Unmanaged<GhosttySurfaceView>.fromOpaque(view.pointer)
                .takeUnretainedValue()
            guard let surface = surfaceView.surfaceHandle,
                  let text = NSPasteboard.general.string(forType: .string) else { return false }
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
    private nonisolated static func confirmReadClipboard(userdata: UnsafeMutableRawPointer?,
                                                         string: UnsafePointer<CChar>?,
                                                         request: UnsafeMutableRawPointer?) {
        guard let userdata, let string, let request else { return }
        let id = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().id
        // Copied here: the C string's lifetime is this call, not the hop.
        let text = String(cString: string)
        let pending = RawPointerBox(pointer: request)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                GhosttySurfaceHost.current?.confirmPaste(text, request: pending, for: id)
            }
        }
    }

    private func confirmPaste(_ text: String, request: RawPointerBox, for id: String) {
        guard surfaces[id] != nil else { return }
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
final class GhosttySurfaceView: NSView {
    /// The session this surface belongs to. Immutable and read from libghostty's
    /// action callback, which arrives on libghostty's own thread.
    nonisolated let id: String

    private weak var host: GhosttySurfaceHost?
    /// Borrowed, not owned. `GhosttySurfaceHost` frees the surface and clears
    /// this first, so nothing here can reach a freed one.
    private var surface: ghostty_surface_t?
    private var redrawScheduled = false
    private var lastGrid: TerminalSize?

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

    init(frame: NSRect, host: GhosttySurfaceHost, id: String) {
        self.host = host
        self.id = id
        super.init(frame: frame)
        // No `CAMetalLayer`. libghostty attaches its own `IOSurfaceLayer` on the
        // first frame and a host supplied layer is left detached, so writing
        // metrics to one would do nothing at all.
        wantsLayer = true
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
        // `createSurface`: `GhosttyService.open` registers the session in its
        // dictionary only afterwards, and its `onResized` handler resolves the
        // session through that dictionary. A report from inside `adopt` would find
        // nothing and be dropped, and because reporting latches on `lastGrid` no
        // later event would correct it, so the pty would stay at its spawn size for
        // the life of the terminal and a full screen program would lay itself out
        // for a grid that does not exist. The seam is made safe here rather than by
        // asking every caller to remember to pull `size(id:)`.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reportInitialGrid() }
        }
    }

    /// Reports the grid as it stands, changed or not. Only the first report goes
    /// through here: it has to arrive even though nothing has moved since the
    /// surface was created.
    private func reportInitialGrid() {
        // Skipped if a layout beat this turn to it, so the caller sees one event
        // rather than two identical ones.
        guard lastGrid == nil, let grid = currentGrid() else { return }
        lastGrid = grid
        host?.report(grid: grid, for: id)
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
        let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface,
                                 UInt32((bounds.width * scale).rounded(.down)),
                                 UInt32((bounds.height * scale).rounded(.down)))
        // The layer libghostty attached, never a cached one of our own.
        layer?.contentsScale = scale

        // Every grid change is reported, not only the ones a font size change
        // causes. A window resize is the common case and the pty has to follow it,
        // or a full screen program keeps drawing for the old size.
        if reportGrid, let grid = currentGrid(), grid != lastGrid {
            lastGrid = grid
            host?.report(grid: grid, for: id)
        }
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
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
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
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Paste, through libghostty's own binding rather than by writing the text.
    ///
    /// The binding is what wraps the text in bracketed paste when the program
    /// asked for it, and what runs the unsafe paste check. It reaches the host's
    /// `read_clipboard_cb`, which is why that callback has to be real.
    @objc func paste(_ sender: Any?) { perform(binding: "paste_from_clipboard") }

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
