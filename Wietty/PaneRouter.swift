import Foundation
import Observation

/// What is covering the local terminal in the main window's pane, and every rule
/// that uncovers it.
///
/// A type of its own, and owned by the app rather than by `ContentView`, for one
/// reason: ⌘, and the app menu item are declared in the scene's `commands`, which
/// cannot reach a view's `@State`. Both ways in then set one property, and the pane
/// draws whatever it says.
///
/// The rules live here rather than in the view's closures because they are what can
/// be wrong, and a rule inside a `.task` closure cannot be asserted in CI. What the
/// pane then shows is `PaneSelection.resolve`'s job, not this one's.
@MainActor
@Observable
final class PaneRouter {
    /// `private(set)` so the answer to "what can change what the pane shows" is the
    /// list of methods below rather than every file holding a reference.
    private(set) var override: PaneOverride?

    /// Puts something in front of the local terminal.
    func show(_ override: PaneOverride) {
        self.override = override
    }

    /// Uncovers the local terminal, whatever was over it.
    func clear() {
        override = nil
    }

    /// The gear's action, and it toggles rather than shows.
    ///
    /// Load bearing, not a convenience. The panel has no close button, and the row
    /// that would otherwise clear it is the row the pane was already showing, which
    /// `GhosttyService.select` refuses to re-select (`guard selected != session`), so
    /// its callback never fires. With no local terminal selected at all, on a fresh
    /// install or after the last one is closed, there is no row to click either. A
    /// gear that only assigned `.settings` left both states with no way out.
    func toggleSettings() {
        override = (override == .settings) ? nil : .settings
    }

    /// A local terminal the user activated takes the pane back.
    ///
    /// Called from the row's own action rather than only from the service's
    /// selection callback, because activating the terminal that is already selected
    /// changes no selection and so produces no callback. That is exactly the row a
    /// user reaches for to leave whatever is covering it.
    func localTerminalActivated() {
        override = nil
    }

    /// A local selection made anywhere else: a click on another row, the MCP server,
    /// a remote client. Only a real selection: the service also selects nil when the
    /// last local terminal is closed, and blanking a pane someone is reading would be
    /// a bug rather than an intent.
    func localSelectionChanged(to session: String?) {
        if session != nil { override = nil }
    }

    /// A connection removed while its session was on screen takes the session with
    /// it and puts the local terminal back, because the rows went with the connection
    /// and a placeholder would be a dead end with nothing left to click out of it.
    ///
    /// Deliberately only the remote case. The settings panel is where connections are
    /// deleted now, so clearing any override here would make the panel vanish under
    /// the cursor of the person using it.
    func connectionsChanged(to ids: [UUID]) {
        if case let .remote(session) = override, !ids.contains(session.connectionId) {
            override = nil
        }
    }
}
