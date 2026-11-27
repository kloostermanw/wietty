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

    /// The rows each connection's last snapshot had, so a remote session selected
    /// between two snapshots can be given its row at once.
    @ObservationIgnored private var remoteRows: [UUID: [RemoteRow]] = [:]
    /// The selected remote session with the rows of the last snapshot that still had a
    /// row carrying it. That is what says which row the selection belongs to once a
    /// restart has given that row another session and the old id is in no snapshot any
    /// more. Nil whenever `override` is not that session (`cover`).
    @ObservationIgnored private var remoteOwner: (session: RemoteSessionRef, rows: [RemoteRow])?

    /// Puts something in front of the local terminal.
    func show(_ override: PaneOverride) {
        cover(with: override)
        guard case let .remote(session) = override, remoteOwner == nil,
              let rows = remoteRows[session.connectionId],
              rows.contains(where: { $0.sessionId == session.sessionId }) else { return }
        remoteOwner = (session, rows)
    }

    /// Every change of `override` but the follow itself goes through here, so the
    /// remembered rows never outlive the remote selection they belong to.
    private func cover(with next: PaneOverride?) {
        override = next
        if case let .remote(session) = next, remoteOwner?.session == session { return }
        remoteOwner = nil
    }

    /// Uncovers the local terminal, whatever was over it.
    func clear() {
        cover(with: nil)
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
        cover(with: (override == .settings) ? nil : .settings)
    }

    /// A local terminal the user activated takes the pane back.
    ///
    /// Called from the row's own action rather than only from the service's
    /// selection callback, because activating the terminal that is already selected
    /// changes no selection and so produces no callback. That is exactly the row a
    /// user reaches for to leave whatever is covering it.
    func localTerminalActivated() {
        cover(with: nil)
    }

    /// A local selection made anywhere else: a click on another row, the MCP server,
    /// a remote client. Only a real selection: the service also selects nil when the
    /// last local terminal is closed, and blanking a pane someone is reading would be
    /// a bug rather than an intent.
    func localSelectionChanged(to session: String?) {
        if session != nil { cover(with: nil) }
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
            cover(with: nil)
        }
        remoteRows = remoteRows.filter { ids.contains($0.key) }
    }

    /// A snapshot of one connection's rows. A selected remote session follows its row:
    /// when the row that carried it now carries another session, that one is selected
    /// instead, which closes the old pane and opens the replacement's
    /// (`RightTerminalView` keys the pane by its session).
    ///
    /// That is a restart, from the pane's stopped screen, the sidebar row or the other
    /// Mac itself, and a local restart selects the replacement in the same way. See
    /// `RemoteSelectionFollow.replacement` for what is not followed: a row that is
    /// gone, and a row that carries no session.
    ///
    /// Only while the remote session is what the pane shows. Covered by a local
    /// terminal, a log or settings there is no remote selection to move.
    func remoteRowsChanged(on connection: UUID, to rows: [RemoteRow]) {
        remoteRows[connection] = rows
        guard case let .remote(session) = override, session.connectionId == connection else { return }
        if rows.contains(where: { $0.sessionId == session.sessionId }) {
            remoteOwner = (session, rows)
            return
        }
        guard let owner = remoteOwner,
              let next = RemoteSelectionFollow.replacement(for: session.sessionId,
                                                           from: owner.rows, to: rows) else { return }
        let followed = RemoteSessionRef(connectionId: connection, sessionId: next)
        override = .remote(followed)
        remoteOwner = (followed, rows)
    }

    /// A workspace removed while its page was on screen takes the page with it, for
    /// the same reason a removed connection takes its session: the card and its rows
    /// went with the workspace, so the page would be a dead end with nothing left in
    /// the sidebar to click out of it.
    ///
    /// Only that page, deliberately. A process log belongs to a workspace too and
    /// stays: it is text this app already holds, so it is still readable after the
    /// workspace is gone. And the app's own settings panel belongs to no workspace at
    /// all, so removing one must not close it under the cursor of whoever is using it.
    func workspacesChanged(to ids: [UUID]) {
        if case let .workspaceSettings(project) = override, !ids.contains(project) {
            cover(with: nil)
        }
    }
}
