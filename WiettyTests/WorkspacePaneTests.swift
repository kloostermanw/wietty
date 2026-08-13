import Testing
import Foundation
import SwiftUI
import WiettyShared
@testable import Wietty

/// "Edit workspace…" puts a page for one workspace in the pane, the way the gear
/// puts the app's own settings there. It is a fifth thing the pane can hold, so it
/// has to answer the same three questions the other four do: what covers the local
/// terminal, what the bar says, and what takes it back off the screen.
@MainActor
@Suite struct WorkspacePaneTests {
    private let workspace = UUID()
    private let otherWorkspace = UUID()

    private func project(_ id: UUID, named name: String) -> Project {
        Project(id: id, url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    @Test func theWorkspacePageCoversTheLocalTerminal() {
        #expect(PaneSelection.resolve(local: "gt:1", override: .workspaceSettings(workspace))
            == .workspaceSettings(workspace))
    }

    /// Nothing local is shown while it is up, which is what keeps the pane from
    /// trying to draw a surface behind the page.
    @Test func theWorkspacePageShowsNoLocalSession() {
        #expect(PaneSelection.workspaceSettings(workspace).localSession == nil)
    }

    /// The bar names the workspace whose page is up. Without it the bar would be
    /// empty over a page that says only "No workspace settings yet", which names
    /// neither the workspace nor what is on screen.
    @Test func theBarNamesTheWorkspaceThePageBelongsTo() {
        let line = NavBarTitle.line(for: .workspaceSettings(workspace),
                                    projects: [project(workspace, named: "wietty")],
                                    remote: { _ in nil })
        #expect(line == "wietty settings")
    }

    /// A workspace removed while its page is up can no longer be named, and a stale
    /// name would be worse than none. The same rule every other branch of the lookup
    /// follows.
    @Test func theBarSaysNothingForAWorkspaceThatIsGone() {
        #expect(NavBarTitle.line(for: .workspaceSettings(workspace), projects: [],
                                 remote: { _ in nil }) == nil)
    }

    /// Removing a workspace takes its page with it. The card and its rows went with
    /// the workspace, so the page would otherwise sit there with nothing in the
    /// sidebar left to click out of it: the same dead end a removed connection used
    /// to leave.
    @Test func removingAWorkspaceUncoversItsPage() {
        let router = PaneRouter()
        router.show(.workspaceSettings(workspace))
        router.workspacesChanged(to: [otherWorkspace])
        #expect(router.override == nil)
    }

    @Test func aWorkspaceStillPresentKeepsItsPage() {
        let router = PaneRouter()
        router.show(.workspaceSettings(workspace))
        router.workspacesChanged(to: [otherWorkspace, workspace])
        #expect(router.override == .workspaceSettings(workspace))
    }

    /// Only the page for the workspace that went. Removing a workspace while the
    /// app's settings panel is up must not close the panel under the cursor of the
    /// person using it, which is the rule the connection list already follows.
    @Test func removingAWorkspaceLeavesTheSettingsPanelUp() {
        let router = PaneRouter()
        router.show(.settings)
        router.workspacesChanged(to: [])
        #expect(router.override == .settings)
    }

    /// A log belongs to a workspace too, and it is the pane's own rule that it
    /// survives: the log is text the app already holds, so it stays readable after
    /// the workspace is gone.
    @Test func removingAWorkspaceLeavesALogUp() {
        let log = PaneOverride.log(ProcessLogRef(projectId: workspace, name: "npm"))
        let router = PaneRouter()
        router.show(log)
        router.workspacesChanged(to: [])
        #expect(router.override == log)
    }

    /// The page itself, which is a placeholder and says so. Asserted rather than
    /// only visible by opening it, the same reason `SettingsTab` is a pure type.
    @Test func thePageSaysThereAreNoWorkspaceSettingsYet() {
        #expect(WorkspaceSettingsView.title == "No workspace settings yet")
        #expect(!WorkspaceSettingsView.message.isEmpty)
        #expect(!WorkspaceSettingsView.systemImage.isEmpty)
    }

    @Test func thePaneRendersTheWorkspacePage() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connections = RemoteConnectionsStore(defaults: defaults)
        let pane = RightTerminalView(
            store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
            stack: GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true"),
            remoteConnections: connections,
            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
            bells: BellNotifier(sink: FakeNotificationSink()),
            selection: .workspaceSettings(workspace))
        #expect(ImageRenderer(content: pane.frame(width: 600, height: 800)).nsImage != nil)
    }
}
