import AppKit
import Foundation

/// A terminal's grid, in cells.
struct TerminalSize: Equatable, Sendable {
    let cols: Int
    let rows: Int
}

/// One terminal's visible screen, as plain text.
///
/// Plain text is not a simplification, it is the API's ceiling.
/// `ghostty_surface_read_text` is the only read back libghostty offers and
/// `ghostty_text_s` carries no attributes, so nothing here can be coloured. This
/// is what a remote viewer's first paint is built from, which is why that paint
/// is monochrome and the live bytes after it are exact.
///
/// The cursor is approximated for the same reason: the C API has no cursor
/// getter of any kind. It is placed at the end of the last non-empty row, which
/// is right for a shell sitting at a prompt and wrong for a full screen program.
/// The next byte the terminal produces moves it to the truth, so the cost is one
/// frame of a misplaced cursor on attach.
struct ScreenSnapshot: Equatable, Sendable {
    let rows: [String]
    let cols: Int
    let cursorX: Int
    let cursorY: Int

    /// Builds a snapshot from rows, placing the cursor as described above.
    init(rows: [String], cols: Int) {
        self.rows = rows
        self.cols = cols
        let lastContent = rows.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self.cursorY = lastContent ?? max(rows.count - 1, 0)
        // Clamped to the last column: a full row would otherwise put the cursor
        // one cell past the right edge, which a viewer draws outside the grid.
        self.cursorX = lastContent.map { min(rows[$0].count, max(cols - 1, 0)) } ?? 0
    }

    init(rows: [String], cols: Int, cursorX: Int, cursorY: Int) {
        self.rows = rows
        self.cols = cols
        self.cursorX = cursorX
        self.cursorY = cursorY
    }
}

enum SurfaceHostError: Error, Equatable {
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
/// terminal is on screen.
@MainActor
protocol TerminalSurfaceHosting: AnyObject {
    /// Creates a surface running `command` in `directory`. `title` labels it,
    /// which is what the workspace badge setting sets.
    func createSurface(id: String, command: String, directory: URL, title: String?) throws

    func destroySurface(id: String)

    /// The view this surface renders into, for the pane to show. Nil for an id
    /// with no surface.
    func view(id: String) -> NSView?

    /// The surface's grid, or nil before it has one. This is the sizing authority
    /// for the substrate: Wietty resizes its own pty to match.
    func size(id: String) -> TerminalSize?

    /// The last `maxLines` rows of the surface's screen, reaching into scrollback
    /// when more rows are asked for than the visible grid holds.
    ///
    /// Reading history is far more expensive than reading the visible screen: on a
    /// 50,000 line scrollback the real host measures 0.14 ms for the grid and 34 ms
    /// for the whole screen, on the main actor. Asking for exactly the grid's row
    /// count is the cheap read, not the expensive one; only more than that reaches
    /// history. A caller that asks for more than the grid on every resize pays the
    /// 34 ms every time, so ask for what you will use.
    func snapshot(id: String, maxLines: Int) -> ScreenSnapshot?

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
    /// The surface's grid changed, so the pty behind it has to follow.
    ///
    /// Every new surface reports its grid once, and that first report is guaranteed
    /// to arrive *after* `createSurface` has returned, on a later main queue turn.
    /// A handler may therefore assume the session it names is one the caller has
    /// finished registering. Getting this wrong is silent: a first report delivered
    /// during `createSurface` would be dropped by a handler whose registry is not
    /// populated yet, and nothing would ever correct the size.
    var onResized: (@MainActor (_ id: String, _ size: TerminalSize) -> Void)? { get set }
    /// libghostty asked for a surface to be closed: the command it was running
    /// exited, or a `close_surface` keybinding fired.
    ///
    /// It means the terminal has ended, not that its surface can go. The handler
    /// must not destroy the surface: the last screen a command printed is what a
    /// user reads when something died, and `destroySurface` is reserved for the
    /// row actually being closed. The host frees nothing on this path either.
    var onCloseRequested: (@MainActor (_ id: String) -> Void)? { get set }
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
final class InertSurfaceHost: TerminalSurfaceHosting {
    var onTitle: (@MainActor (String, String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    var onResized: (@MainActor (String, TerminalSize) -> Void)?
    var onCloseRequested: (@MainActor (String) -> Void)?

    func createSurface(id: String, command: String, directory: URL, title: String?) throws {
        throw SurfaceHostError.surfaceFailed
    }
    func destroySurface(id: String) {}
    func view(id: String) -> NSView? { nil }
    func size(id: String) -> TerminalSize? { nil }
    func snapshot(id: String, maxLines: Int) -> ScreenSnapshot? { nil }
}
