import Foundation
import WiettyShared

/// One terminal row of another Mac, as far as the pane's selection needs it: the row's
/// own id, which it keeps for its whole life, the session it carries now, which a
/// restart or a revival replaces, and whether it is an agent.
struct RemoteRow: Equatable {
    let id: UUID
    let sessionId: String
    var isAgent: Bool = false

    /// Every row of one connection's snapshot, in the snapshot's order.
    static func rows(in workspaces: [RemoteWorkspace]) -> [RemoteRow] {
        workspaces.flatMap { workspace in
            workspace.sessions.map {
                RemoteRow(id: $0.id, sessionId: $0.sessionId, isAgent: $0.kind == .claude)
            }
        }
    }

    /// Whether the row carrying `sessionId` is an agent. False when no row carries it,
    /// so a session the snapshot does not know gets the terminal wording.
    static func isAgent(sessionId: String, in rows: [RemoteRow]) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return rows.first { $0.sessionId == sessionId }?.isAgent ?? false
    }
}

/// Where a selected remote session went when its row got another one.
///
/// A restart on the other Mac closes the row's session and opens a new one for the same
/// row: the row keeps its id and gets a new session id. The selection is a session id,
/// so without this the pane would stay on the session that ended while its replacement
/// runs one click away. A local restart selects the replacement
/// (`GhosttyService.open`); this is the same for a remote row, and it holds whoever
/// restarted it: the stopped screen's button, the sidebar row's, or the other Mac.
enum RemoteSelectionFollow {
    /// The session to select instead of `selected`, or nil to leave the selection.
    ///
    /// - Parameter selected: the selected session's id.
    /// - Parameter old: rows of the connection from a snapshot that still had a row
    ///   carrying `selected`. That is what says which row owned it.
    /// - Parameter new: rows of the same connection now.
    ///
    /// Nil when `old` has no row carrying `selected` (nothing says which row to
    /// follow), when some row in `new` still carries it (it has not been replaced),
    /// when the owning row is gone from `new` (closed: nothing to follow to), and when
    /// that row carries no session (a row between two sessions, or one whose terminal
    /// is gone and not opened again).
    static func replacement(for selected: String, from old: [RemoteRow], to new: [RemoteRow]) -> String? {
        guard !selected.isEmpty,
              let owner = old.first(where: { $0.sessionId == selected }),
              !new.contains(where: { $0.sessionId == selected }),
              let now = new.first(where: { $0.id == owner.id }),
              !now.sessionId.isEmpty else { return nil }
        return now.sessionId
    }
}
