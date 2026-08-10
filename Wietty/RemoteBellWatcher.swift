import Foundation
import WiettyShared

/// A remote session that is asking for attention, with what a notification needs
/// to say about it.
struct RemoteRinger: Equatable {
    let sessionId: String
    let label: String
    let workspace: String
}

/// What changed about one connection's bells since the last snapshot.
struct RemoteBellDiff: Equatable {
    /// Sessions whose flag just turned on, in snapshot order.
    var ringing: [RemoteRinger] = []
    /// Session ids whose flag just turned off, whose notifications can be withdrawn.
    var cleared: Set<String> = []

    var isEmpty: Bool { ringing.isEmpty && cleared.isEmpty }
}

/// Turns a stream of whole snapshots into bell events.
///
/// A local bell arrives as an event, so it happens once by construction. A remote
/// one does not: the protocol pushes the complete workspace list on every change
/// (see `documentation/remote-access.md`), so "a bell rang" is only visible as a
/// `needs_attention` flag that was off in the previous snapshot and is on in this
/// one. This keeps the previous answer per connection so that difference can be
/// taken.
///
/// Two rules matter more than the diff itself:
///
/// The first snapshot from a connection is adopted in silence. Connecting to a Mac
/// whose agent has been waiting for an hour must not announce it as something that
/// just happened, and on app launch every connection delivers such a snapshot at
/// once.
///
/// What is known survives a drop. `RemoteWorkspaceStore` keeps its last snapshot
/// when a connection drops and replaces it on reconnect, so treating a reconnect as
/// a first snapshot would re announce every waiting agent on every network blip,
/// while forgetting nothing means a bell that rang while the link was down is still
/// reported once the link is back. Both are what keeping the set gives.
struct RemoteBellWatcher {
    /// The flagged session ids per connection, as of the last snapshot seen. Absent
    /// means no snapshot has been seen yet, which is not the same as an empty set.
    private var known: [UUID: Set<String>] = [:]

    mutating func diff(connection: UUID, flagged: [RemoteRinger]) -> RemoteBellDiff {
        let ids = Set(flagged.map(\.sessionId))
        defer { known[connection] = ids }
        guard let before = known[connection] else { return RemoteBellDiff() }
        return RemoteBellDiff(ringing: flagged.filter { !before.contains($0.sessionId) },
                              cleared: before.subtracting(ids))
    }

    /// Forgets a connection, so one removed and added again starts silent rather
    /// than reporting its whole backlog as new bells.
    mutating func forget(connection: UUID) {
        known.removeValue(forKey: connection)
    }

    /// The sessions a snapshot says are asking for attention.
    ///
    /// Reads the wire model directly rather than going through
    /// `RemoteProjectAdapter`, which synthesises placeholder `Project` values for the
    /// sidebar and drops the one thing needed here: the workspace a session belongs
    /// to, for the notification's title.
    static func flagged(in workspaces: [RemoteWorkspace]) -> [RemoteRinger] {
        workspaces.flatMap { workspace in
            workspace.sessions.filter(\.needsAttention).map {
                RemoteRinger(sessionId: $0.sessionId, label: $0.label, workspace: workspace.name)
            }
        }
    }
}
