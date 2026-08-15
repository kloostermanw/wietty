import Foundation

/// One remote session, by the connection it lives on and its id there.
///
/// Deliberately excludes the row's label, which follows the foreground job on the
/// other Mac and changes while the session is on screen: a selection keyed on it
/// would unmark the row mid-command.
struct RemoteSessionRef: Equatable, Hashable {
    let connectionId: UUID
    let sessionId: String
}

/// One process's log, by the workspace it belongs to and its name there.
///
/// The workspace is part of the identity because two workspaces routinely declare
/// a process under the same name. `isTest` is too: processes and tests are
/// separate namespaces that may share a name, so a test called `npm` is not the
/// process called `npm`.
struct ProcessLogRef: Equatable, Hashable {
    let projectId: UUID
    let name: String
    var isTest: Bool = false
}

/// What is covering the local terminal, if anything.
///
/// One value rather than three, because these are the things that can take the
/// pane from a local terminal and no two of them can be on screen at once. Held
/// apart, every place that set one would have to remember to clear the others, and
/// the one that forgot would leave the sidebar marking a row the pane is not
/// showing.
///
/// Settings is one of them rather than a window of its own, which is also why the
/// panel has no close button: activating a terminal row clears the override, and the
/// gear toggles it. `PaneRouter` owns both rules.
enum PaneOverride: Equatable {
    case remote(RemoteSessionRef)
    case log(ProcessLogRef)
    case settings
    /// One workspace's own page, by workspace id. Reached from "Edit workspace…" in
    /// the card's menu, and covering the terminal for the same reason `settings`
    /// does: it is a page rather than a window, so it goes where every other page
    /// goes.
    case workspaceSettings(UUID)
}

/// What the main window's pane is showing, and therefore which sidebar row is
/// marked.
///
/// The pane holds one thing at a time, three of which the sidebar lists and one of
/// which (settings) belongs to no workspace, so this is the one place that says which
/// won. It is derived rather than stored: `GhosttyService` owns the local selection
/// and `PaneRouter` holds the override, and neither has to know about the other.
///
/// An override covers the local selection instead of replacing it. Nothing about
/// the local terminal changes while a remote session, a log or settings is on screen,
/// so clearing the override puts the local terminal back rather than leaving an empty
/// pane. It is also why leaving settings cannot rely on the selection *changing*: the
/// covered terminal is still the selected one. See `PaneRouter`.
enum PaneSelection: Equatable {
    /// Nothing selected. The pane shows its placeholder.
    case none
    /// A local terminal on this Mac, by session id.
    case local(String)
    /// A session on another Mac, reached over the LAN remote protocol.
    case remote(RemoteSessionRef)
    /// A supervised process's output.
    case processLog(ProcessLogRef)
    /// The app's own settings. The one thing here that belongs to no workspace, so
    /// it marks no row in the sidebar and the bar above the pane names it directly.
    case settings
    /// One workspace's own page, by workspace id.
    case workspaceSettings(UUID)

    /// - Parameter local: `GhosttyService.selected`, mirrored into SwiftUI state.
    /// - Parameter override: whatever a sidebar row put in front of it, if any.
    static func resolve(local: String?, override: PaneOverride?) -> PaneSelection {
        switch override {
        case let .remote(session): return .remote(session)
        case let .log(process): return .processLog(process)
        case .settings: return .settings
        case let .workspaceSettings(project): return .workspaceSettings(project)
        case nil: break
        }
        if let local { return .local(local) }
        return .none
    }

    /// The local session the pane should show, which is nil for everything else.
    /// A covered local terminal and no terminal at all put the same view on screen,
    /// so the pane has one branch for them rather than two: switching between them
    /// must not re-parent a live surface.
    var localSession: String? {
        if case let .local(session) = self { return session }
        return nil
    }

    /// Whether a local sidebar row is the one on screen.
    func selects(localSession sessionId: String) -> Bool {
        self == .local(sessionId)
    }

    /// Whether a remote sidebar row is the one on screen. The connection is part of
    /// the question: two Macs can hand out the same session id, and matching on the
    /// id alone would mark a row on the wrong connection.
    func selects(remoteSession sessionId: String, on connectionId: UUID) -> Bool {
        self == .remote(RemoteSessionRef(connectionId: connectionId, sessionId: sessionId))
    }

    /// Whether a process row's log is the one on screen.
    func selects(processLog process: ProcessLogRef) -> Bool {
        self == .processLog(process)
    }

    /// Whether the settings panel is the one on screen, which is what marks the gear
    /// in the bar the way the sidebar marks a row.
    var showsSettings: Bool {
        self == .settings
    }
}
