import Testing
import Foundation
import SwiftUI
import WiettyShared
@testable import Wietty

/// The Agents tab, which is where the list the workspace menu offers is edited.
///
/// It is the tab that existed ahead of its settings, so filling it is what deletes
/// its placeholder. Rendered here in the states the seeded list never reaches on its
/// own: several agents, none at all, and a row being edited.
@MainActor
@Suite struct AgentSettingsTests {
    private func settings(_ agents: [AgentDefinition]) -> SettingsView {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connections = RemoteConnectionsStore(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.agents = agents
        return SettingsView(store: store, remoteConnections: connections,
                            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
                            bells: BellNotifier(sink: FakeNotificationSink()),
                            tab: .agents)
    }

    @Test func theTabRendersAListOfAgents() {
        let view = settings([.claude,
                             AgentDefinition(name: "Codex", command: "codex",
                                             defaultArguments: "--model o3")])
        #expect(ImageRenderer(content: view.frame(width: 600, height: 800)).nsImage != nil)
    }

    /// The list can be emptied, and the tab has to say so rather than drawing a
    /// section with nothing in it.
    @Test func theTabRendersAnEmptyList() {
        #expect(ImageRenderer(content: settings([]).frame(width: 600, height: 800))
            .nsImage != nil)
    }

    /// The editing branch, which the tab never shows on the way in, so a render of
    /// the tab alone covers the reading half only. The row's `init` takes the state
    /// for the same reason `NotificationSettings.init` takes a permission.
    @Test func anAgentRowRendersWhileBeingReadAndWhileBeingEdited() {
        for editing in [false, true] {
            let view = Form {
                AgentRow(agent: .claude, isEditing: editing, onUpdate: { _ in }, onDelete: {})
            }
            .formStyle(.grouped)
            #expect(ImageRenderer(content: view.frame(width: 600, height: 400)).nsImage != nil,
                    "editing: \(editing) failed to render")
        }
    }

    /// The tab is no longer one of the empty ones, which is the whole point of the
    /// space it was holding.
    @Test func theAgentsTabIsNoLongerAPlaceholder() {
        #expect(SettingsTab.agents.title == "Agents")
        #expect(SettingsTab.allCases.count == 5)
    }
}
