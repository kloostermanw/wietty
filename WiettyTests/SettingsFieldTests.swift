import Testing
import AppKit
import SwiftUI
import WiettyShared
@testable import Wietty

/// What the settings fields must not do to the window.
///
/// The pane's width is a divider the user drags, and its floor
/// (`SidebarWidth.paneMinimum`) is what `SidebarWidth.windowMinimumWidth` is built
/// from. A field that asked for the width of what is typed into it would move that
/// floor, so one long value in one tab would change how small the whole window can
/// get. `SettingsPaneTests.theTabControlDoesNotWidenThePaneFloor` pins the same rule
/// for the tab control; these pin it for the tabs that hold fields.
@MainActor
@Suite struct SettingsFieldTests {
    private func settings(_ tab: SettingsTab,
                          agents: [AgentDefinition] = [.claude],
                          connections: [RemoteConnection] = []) -> SettingsView {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.agents = agents
        let connectionStore = RemoteConnectionsStore(defaults: defaults)
        for connection in connections { connectionStore.add(connection) }
        return SettingsView(store: store, remoteConnections: connectionStore,
                            remoteWorkspaces: RemoteWorkspacesController(connections: connectionStore),
                            bells: BellNotifier(sink: FakeNotificationSink()),
                            desktopNotifications: .fake(),
                            ghosttyColors: GhosttyColorSettings(host: FakeSurfaceHost(), file: .temporary()),
                            tab: tab)
    }

    /// The width the panel asks for when it is offered the pane's floor.
    private func widthAtPaneFloor<V: View>(_ view: V) -> Double {
        let size = NSHostingController(rootView: view)
            .sizeThatFits(in: NSSize(width: SidebarWidth.paneMinimum,
                                     height: CGFloat.greatestFiniteMagnitude))
        return Double(size.width)
    }

    @Test func theAgentsTabFitsThePaneFloor() {
        #expect(widthAtPaneFloor(settings(.agents)) == SidebarWidth.paneMinimum)
    }

    @Test func theRemoteTabFitsThePaneFloor() {
        let connection = RemoteConnection(id: UUID(), name: "Office Mac",
                                          host: "192.168.1.20", port: 7434, token: "t")
        #expect(widthAtPaneFloor(settings(.remote, connections: [connection]))
            == SidebarWidth.paneMinimum)
    }

    /// The case in the report: a value longer than the pane is wide. A row that
    /// draws the value as plain text has the string's width as its ideal width; a
    /// field has a field's width, and what does not fit scrolls inside it.
    @Test func aLongValueDoesNotWidenTheAgentsTab() {
        let long = String(repeating: "123456789abcdefghijklmnopq", count: 8)
        let agent = AgentDefinition(name: long, command: long, defaultArguments: long)
        #expect(widthAtPaneFloor(settings(.agents, agents: [agent])) == SidebarWidth.paneMinimum)
    }

    /// The same for a token, which is the longest thing anyone pastes into this
    /// panel and is on a tab with four fields in a row.
    @Test func aLongTokenDoesNotWidenTheRemoteTab() {
        let connection = RemoteConnection(id: UUID(), name: "Office Mac",
                                          host: "192.168.1.20", port: 7434,
                                          token: String(repeating: "a1b2c3d4", count: 24))
        #expect(widthAtPaneFloor(settings(.remote, connections: [connection]))
            == SidebarWidth.paneMinimum)
    }

    /// A row being edited is the state with the most fields on screen at once, and
    /// the one the report is a screenshot of.
    @Test func anAgentRowBeingEditedFitsThePaneFloor() {
        let long = String(repeating: "123456789abcdefghijklmnopq", count: 8)
        let view = Form {
            AgentRow(agent: AgentDefinition(name: long, command: long, defaultArguments: long),
                     isEditing: true, onUpdate: { _ in }, onDelete: {})
        }
        .formStyle(.grouped)
        #expect(widthAtPaneFloor(view) == SidebarWidth.paneMinimum)
    }
}
