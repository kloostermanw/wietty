import Foundation

package enum SurfaceHostError: Error, Equatable {
    case initFailed(String)
    case surfaceFailed
}

/// The libghostty surface operations the rest of the app needs.
///
/// The single seam onto libghostty. `GhosttySurfaceHost` is the only type that
/// imports GhosttyKit, and nothing above this protocol may: the API is
/// explicitly unstable, so the blast radius of a breaking release has to be one
/// file. It also means every test in this substrate runs with no Metal device and
/// no framework, against `FakeSurfaceHost`.
///
/// A surface owns an `NSView` for its whole life rather than only while visible.
/// That is libghostty's rule, not a choice: `ghostty_surface_new` takes the view
/// in its config (`ghostty_platform_macos_s` is `{ void *nsview; }`), so there is
/// no such thing as a surface without one. The pane adds and removes the view
/// from the window's hierarchy, which is how Ghostty's own tabs work and what
/// keeps a terminal's scrollback and its running command alive while another
/// terminal is on screen. Handing that view to the pane is `TerminalSurfaceViewing`,
/// deliberately not this protocol: an `NSView` is the one thing here that AppKit
/// has to be imported for, and everything else a host does is answerable without a
/// window. Keeping the two apart is what lets this protocol, and so `GhosttyService`
/// and `GhosttyStack` with it, live in a target that never imports AppKit.
@MainActor
package protocol TerminalSurfaceHosting: AnyObject {
    /// Creates the surface of terminal `id`, in `directory`, as a viewer of that
    /// terminal's stream: the host joins it to the session through a bridge of its
    /// own (the app's `TerminalBridge`, attached to `LocalStreamServer` as the
    /// session's local viewer). What the surface runs to get there is the host's
    /// business, and no part of the core builds it. `title` labels the surface,
    /// which is what the workspace badge setting sets.
    ///
    /// The session must be live in the census when this is called: the bridge may
    /// attach before it returns.
    func createSurface(id: String, directory: URL, title: String?) throws

    /// Frees the surface of `id` and stops its bridge, which removes the bridge's
    /// socket file. A surface that does not exist is nothing to do.
    func destroySurface(id: String)

    /// The surface's grid, or nil before it has one. What the surface lays out, not
    /// the terminal's grid: the server is the only thing that resizes a terminal
    /// (decision P4), and the grid in force is its screen model's. The two agree
    /// once the surface shows the grid in force, its own claimed or one imposed.
    /// Nothing in the app or the core reads it any more; only the gated
    /// coexistence check (`GhosttyVtCoexistenceTests`) does.
    func size(id: String) -> TerminalSize?

    /// The surface's cell size, configured padding and backing scale, which is what
    /// turns a grid into the size of a view that shows it and back
    /// (`SurfaceMetrics`). Nil for an unknown surface, and for one whose cell size is
    /// not known yet. A real host knows it from `createSurface` on, at the scale the
    /// view was last laid out at; `onMetricsChanged` says when that changes.
    func metrics(id: String) -> SurfaceMetrics?

    /// Gives the surface's view the size that shows `grid`. Nil returns it to the
    /// pane's size.
    ///
    /// Applied whether or not the surface is on display: a view no pane holds is
    /// given the size itself, so a hidden surface stays at the grid in force, and a
    /// pane that shows it finds it at that size. The view stays pinned to the top left of the pane: a smaller grid
    /// leaves a margin in the terminal's background colour, a larger one is clipped.
    /// The size follows the surface's metrics, so it is recomputed when they change
    /// (another display's scale, a font or padding change) without being imposed
    /// again. `onResized` keeps reporting the surface's grid as its view's size
    /// changes, an imposed size included.
    ///
    /// Any grid is accepted and held to what can be shown: at least 1 by 1, at most
    /// 10,000 per side (the stream protocol's range), and at most what the
    /// renderer's largest texture holds at the surface's cell size and scale. A grid
    /// past that last bound is shown with fewer columns or rows than it has, which
    /// is the same as clipping it: the cells beyond are not on screen.
    func impose(grid: TerminalSize?, on id: String)

    /// libghostty reported a title change (OSC 0 or OSC 2).
    var onTitle: (@MainActor (_ id: String, _ title: String) -> Void)? { get set }
    /// libghostty reported a bell.
    var onBell: (@MainActor (_ id: String) -> Void)? { get set }
    /// A process asked for a desktop notification (`OSC 9` or `OSC 777`).
    ///
    /// Its own callback rather than a bell with words attached, because the two are
    /// treated differently everywhere downstream: a bell is one ambiguous byte a
    /// shell also rings for tab completion, and this is a message a program chose to
    /// send. `title` is empty for `OSC 9;text`, which carries a body and nothing else.
    var onDesktopNotification: (@MainActor (_ id: String, _ title: String, _ body: String) -> Void)? { get set }
    /// The surface's grid changed: its view was given another size, by the pane or
    /// by `impose(grid:on:)`.
    ///
    /// A report, not a claim, and nothing in the core acts on it: the pty and the
    /// model are resized only by a viewer's claim, which for the own pane is made by
    /// the app from the grid that fits the pane (`PaneGrid`). At most it says the
    /// surface has settled.
    ///
    /// Every new surface reports its grid once, and that first report is guaranteed
    /// to arrive *after* `createSurface` has returned, on a later main queue turn.
    /// A handler may therefore assume the session it names is one the caller has
    /// finished registering. Getting this wrong is silent: a first report delivered
    /// during `createSurface` would be dropped by a handler whose registry is not
    /// populated yet, and nothing would ever correct the size.
    ///
    /// Nothing in the app or the core sets a handler for it any more.
    var onResized: (@MainActor (_ id: String, _ size: TerminalSize) -> Void)? { get set }
    /// The surface's `metrics(id:)` changed: its window moved to a display with
    /// another scale, its font changed, or a reloaded configuration changed its
    /// padding.
    ///
    /// Separate from `onResized` because the two do not imply each other: a move
    /// between a scale 1 and a scale 2 display doubles the cell and the padding and
    /// leaves the grid as it was, so no grid is reported, yet the grid a pane of a
    /// given size holds can change. Like the grid, the first report arrives after
    /// `createSurface` has returned.
    ///
    /// Nothing in the app or the core sets a handler for it any more: the pane's
    /// grid hears of a metrics change from the host directly
    /// (`GhosttySurfaceHost.reportMetrics`, which tells it the pane's new own grid).
    var onMetricsChanged: (@MainActor (_ id: String) -> Void)? { get set }
    /// libghostty asked for a surface to be closed: the command it was running
    /// exited, or a `close_surface` keybinding fired.
    ///
    /// It means the terminal has ended, not that its surface can go. The handler
    /// must not destroy the surface: the last screen a command printed is what a
    /// user reads when something died, and `destroySurface` is reserved for the
    /// row actually being closed. The host frees nothing on this path either.
    var onCloseRequested: (@MainActor (_ id: String) -> Void)? { get set }
    /// The user typed into a surface: a keystroke reached the view the pane shows.
    ///
    /// Raised on every key press rather than filtered, because the one thing it
    /// drives (dropping the terminal's attention flag) is idempotent and cheap: the
    /// store no-ops once the flag is down. It is the app's evidence that the user is
    /// answering a terminal they can see, so a bell that rang while Wietty was in
    /// the background clears the moment they type, with no click on the row first.
    var onInput: (@MainActor (_ id: String) -> Void)? { get set }

    /// What libghostty resolved for `desktop-notifications`, both as it stands and
    /// as it would stand without Wietty's own overlay
    /// (`GhosttyOverrideFile`).
    ///
    /// Two values rather than one because the Settings toggle has to be able to say
    /// which answer won. When they differ, the user's own Ghostty config asked for
    /// something Wietty is deliberately overriding, and a toggle that showed only
    /// the winner would look like it had ignored their config.
    ///
    /// Read from libghostty rather than from the file, because the file is one of
    /// several inputs and only libghostty resolves them. `OSC 9` and `OSC 777` are
    /// gated on this: false means a program asking for a notification is answered by
    /// nothing at all, no matter what the rest of `docs/notifications.md` describes.
    var desktopNotifications: (effective: Bool, userConfig: Bool) { get }

    /// Whether a surface created now starts with grapheme clustering (DEC mode
    /// 2027) on: true unless the resolved Ghostty configuration sets
    /// `grapheme-width-method = legacy`.
    ///
    /// Here because a terminal's `TerminalScreenModel` has to lay out an emoji made
    /// of several code points in as many cells as the surface does, and this one
    /// key decides that. The model cannot read the configuration itself: only
    /// libghostty resolves the files that make it up, and only the host may ask.
    var graphemeClustering: Bool { get }

    /// Rebuilds the configuration from disk and hands it to the app and every live
    /// surface, so a setting changed in the Settings window takes effect on
    /// terminals that are already open rather than on the next launch.
    func reloadConfig()
}

/// A host with no libghostty behind it, for a launch where libghostty could not
/// initialise.
///
/// Exists because `GhosttyStack` takes a non-optional host: the composition root
/// has to hand it something even when there is nothing to hand it. Every surface
/// fails, which costs nothing, because such a stack installs
/// `UnavailableTerminalService` and never asks for a surface at all. The reason
/// libghostty would not start travels separately, as the `hostFailure` that stack
/// both reports and throws.
@MainActor
package final class InertSurfaceHost: TerminalSurfaceHosting {
    /// Spelled out because the implicit one is internal and `TerminalStack`, which
    /// is the only thing that builds one, is in the app.
    package init() {}

    package var onTitle: (@MainActor (String, String) -> Void)?
    package var onBell: (@MainActor (String) -> Void)?
    package var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    package var onResized: (@MainActor (String, TerminalSize) -> Void)?
    package var onMetricsChanged: (@MainActor (String) -> Void)?
    package var onCloseRequested: (@MainActor (String) -> Void)?
    package var onInput: (@MainActor (String) -> Void)?

    package func createSurface(id: String, directory: URL, title: String?) throws {
        throw SurfaceHostError.surfaceFailed
    }
    package func destroySurface(id: String) {}
    package func size(id: String) -> TerminalSize? { nil }
    package func metrics(id: String) -> SurfaceMetrics? { nil }
    package func impose(grid: TerminalSize?, on id: String) {}
    /// libghostty's own default, which is what a launch with no libghostty would
    /// have resolved to. Reporting the default rather than false keeps the Settings
    /// toggle from claiming notifications are turned off when the truth is that
    /// there is no terminal at all to turn them off for.
    package var desktopNotifications: (effective: Bool, userConfig: Bool) { (true, true) }
    /// libghostty's own default again.
    package var graphemeClustering: Bool { true }
    package func reloadConfig() {}
}
