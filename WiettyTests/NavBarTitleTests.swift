import Testing
import Foundation
@testable import Wietty

/// What the bar above the pane says.
///
/// Split from the view so all five states can be asserted without SwiftUI: the
/// bar is a `Text` around this, and everything that can be wrong is here.
@MainActor
@Suite struct NavBarTitleTests {
    private let connection = UUID()

    private func project(_ name: String, sessions: [String] = []) -> Project {
        Project(id: UUID(),
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                terminals: sessions.map { TerminalRef(label: "Terminal", sessionId: $0) },
                terminalSeq: 0,
                claudeSeq: 0,
                collapsed: false)
    }

    // MARK: - Where the pane's content comes from

    @Test func nothingSelectedHasNoOrigin() {
        #expect(NavBarTitle.origin(for: .none, projects: [], remote: { _ in nil }) == nil)
    }

    @Test func aLocalTerminalNamesTheWorkspaceHoldingItsRow() {
        let projects = [project("api", sessions: ["gt:1"]), project("web", sessions: ["gt:2"])]
        #expect(NavBarTitle.origin(for: .local("gt:2"), projects: projects, remote: { _ in nil })
                == PaneOrigin(workspace: "web"))
    }

    /// A session id no row carries has no workspace to name. Reachable in the frame
    /// between a terminal being opened and the row being written, and while a row is
    /// being removed, so it must not be a crash or a wrong name.
    @Test func aLocalTerminalNoRowHoldsHasNoOrigin() {
        let projects = [project("api", sessions: ["gt:1"])]
        #expect(NavBarTitle.origin(for: .local("gt:9"), projects: projects, remote: { _ in nil }) == nil)
    }

    @Test func aProcessLogNamesItsOwnWorkspace() {
        let projects = [project("api"), project("web")]
        let log = ProcessLogRef(projectId: projects[1].id, name: "npm")
        #expect(NavBarTitle.origin(for: .processLog(log), projects: projects, remote: { _ in nil })
                == PaneOrigin(workspace: "web"))
    }

    @Test func aProcessLogOfARemovedWorkspaceHasNoOrigin() {
        let log = ProcessLogRef(projectId: UUID(), name: "npm")
        #expect(NavBarTitle.origin(for: .processLog(log), projects: [project("api")],
                                   remote: { _ in nil }) == nil)
    }

    /// A remote session's name lives on the other Mac, so it is looked up rather
    /// than derived. The lookup is a closure because the answer comes from a live
    /// snapshot, which this has no business knowing about.
    @Test func aRemoteSessionIsNamedByItsLookup() {
        let session = RemoteSessionRef(connectionId: connection, sessionId: "gt:7")
        let origin = NavBarTitle.origin(for: .remote(session), projects: []) { asked in
            asked == session ? PaneOrigin(workspace: "web-app", connection: "Office Mac") : nil
        }
        #expect(origin == PaneOrigin(workspace: "web-app", connection: "Office Mac"))
    }

    /// A connection that has not delivered a snapshot yet, or a session that has
    /// left it, answers nothing. The bar is empty rather than showing a stale name.
    @Test func aRemoteSessionWithNoSnapshotHasNoOrigin() {
        let session = RemoteSessionRef(connectionId: connection, sessionId: "gt:7")
        #expect(NavBarTitle.origin(for: .remote(session), projects: [], remote: { _ in nil }) == nil)
    }

    // MARK: - How that reads

    @Test func noOriginIsNoTitle() {
        #expect(NavBarTitle.text(for: nil) == nil)
    }

    @Test func somethingOnThisMacIsJustTheWorkspace() {
        #expect(NavBarTitle.text(for: PaneOrigin(workspace: "api")) == "api")
    }

    /// The connection first, because two Macs routinely have a workspace with the
    /// same name and "web-app" alone would say nothing about which one. The sidebar
    /// already reads this way: the section header is the connection, the card under
    /// it is the workspace.
    @Test func somethingOnAnotherMacNamesTheConnectionFirst() {
        #expect(NavBarTitle.text(for: PaneOrigin(workspace: "web-app", connection: "Office Mac"))
                == "Office Mac / web-app")
    }

    // MARK: - The whole line

    /// Settings belongs to no workspace, so there is nothing for the lookup to find.
    @Test func settingsHasNoWorkspaceToName() {
        #expect(NavBarTitle.origin(for: .settings, projects: [project("api")],
                                   remote: { _ in nil }) == nil)
    }

    /// Having no workspace must not leave the bar empty: the panel names itself. The
    /// composition lives here rather than in the view so the one line the bar can
    /// say that is not a workspace is still asserted in CI.
    @Test func settingsNamesThePanel() {
        #expect(NavBarTitle.line(for: .settings, projects: [], remote: { _ in nil }) == "Settings")
    }

    @Test func aLocalTerminalsLineIsItsWorkspace() {
        let projects = [project("api", sessions: ["gt:1"])]
        #expect(NavBarTitle.line(for: .local("gt:1"), projects: projects,
                                 remote: { _ in nil }) == "api")
    }

    @Test func nothingSelectedIsAnEmptyLine() {
        #expect(NavBarTitle.line(for: .none, projects: [], remote: { _ in nil }) == nil)
    }

    /// `line` is what the view calls, so it has to forward the remote lookup as well
    /// as the workspace list. A `line` that dropped the closure would empty the bar for
    /// every session on another Mac, and the local case above would not notice.
    @Test func aRemoteSessionsLineNamesItsConnection() {
        let session = RemoteSessionRef(connectionId: connection, sessionId: "gt:7")
        #expect(NavBarTitle.line(for: .remote(session), projects: [],
                                 remote: { _ in PaneOrigin(workspace: "web-app",
                                                           connection: "Office Mac") })
                == "Office Mac / web-app")
    }
}
