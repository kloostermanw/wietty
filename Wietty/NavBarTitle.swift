import Foundation

/// Where the thing in the pane comes from.
///
/// Two fields rather than one string, so the formatting rule lives in one place
/// and the lookup that finds the workspace does not have to know it.
struct PaneOrigin: Equatable {
    let workspace: String
    /// The Mac serving it, or nil for anything on this one.
    var connection: String?
}

/// What the bar above the pane says.
///
/// Two steps, both pure, because they can be wrong in different ways: finding the
/// workspace a selection belongs to, and turning that into a line of text. The
/// view is a `Text` around them.
@MainActor
enum NavBarTitle {
    /// The workspace the pane's content belongs to, if it can still be named.
    ///
    /// Nil is a real answer at every branch and never a crash: a session id can
    /// outlive the row that carried it, a workspace can be removed while its log is
    /// on screen, and a connection may not have delivered a snapshot yet. An empty
    /// bar is right in all three cases, and a stale name would be worse than none.
    ///
    /// - Parameter remote: the lookup for a session on another Mac, which lives in
    ///   a live snapshot this has no business knowing about.
    static func origin(for selection: PaneSelection,
                       projects: [Project],
                       remote: (RemoteSessionRef) -> PaneOrigin?) -> PaneOrigin? {
        switch selection {
        case .none:
            return nil
        case let .local(sessionId):
            let owner = projects.first { project in
                project.terminals.contains { $0.sessionId == sessionId }
            }
            return owner.map { PaneOrigin(workspace: $0.name) }
        case let .processLog(log):
            return projects.first { $0.id == log.projectId }
                .map { PaneOrigin(workspace: $0.name) }
        case let .remote(session):
            return remote(session)
        }
    }

    /// The line itself. The connection comes first for anything on another Mac,
    /// because two Macs routinely have a workspace with the same name and the
    /// workspace alone would not say which one. That is also how the sidebar reads:
    /// the section header is the connection, the card under it is the workspace.
    static func text(for origin: PaneOrigin?) -> String? {
        guard let origin else { return nil }
        guard let connection = origin.connection else { return origin.workspace }
        return "\(connection) / \(origin.workspace)"
    }
}
