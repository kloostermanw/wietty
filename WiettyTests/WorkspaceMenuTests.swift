import Testing
import Foundation
import SwiftUI
@testable import Wietty

/// What a workspace card's context menu offers, in what order, and which of it a
/// remote card cannot offer at all.
///
/// A pure type rather than a `switch` inside the card's `.contextMenu`, for the same
/// reason `NavBarView.trailingButtons` and `SettingsTab` are: the set of things a
/// menu offers is a fact about the app, and a fact about the app belongs in CI
/// rather than being checkable only by right clicking a card.
@Suite struct WorkspaceMenuTests {
    private func local(syncEnabled: Bool = true) -> [WorkspaceMenuItem] {
        WorkspaceMenu.items(isLocal: true, syncEnabled: syncEnabled)
    }

    @Test func theLocalMenuOpensWithTheThingsThatAddSomething() {
        #expect(local().prefix(4) == [.addTerminal, .addAgent, .addAgentWithArgs, .addWorkspace])
    }

    /// A separator, and everything that acts on the workspace itself below it. The
    /// four above it all add something; mixing "Remove" in with them is how a click
    /// meant for one lands on the other.
    @Test func actingOnTheWorkspaceItselfIsBelowASeparator() {
        #expect(local() == [.addTerminal, .addAgent, .addAgentWithArgs, .addWorkspace,
                            .separator, .editWorkspace, .renameWorkspace, .removeWorkspace])
    }

    /// Sync can only be turned on, so the item is there only while it is off. It was
    /// the same before this menu was rebuilt.
    @Test func enablingSyncIsOfferedOnlyWhileSyncIsOff() {
        #expect(local(syncEnabled: false).contains(.enableConfigSync))
        #expect(!local(syncEnabled: true).contains(.enableConfigSync))
        #expect(local(syncEnabled: false).last == .removeWorkspace)
    }

    /// A remote card is another Mac's workspace, served over the LAN protocol, and
    /// the protocol has exactly two things to open with. The agent list is this Mac's
    /// preference and means nothing over there; the workspace is not this app's to
    /// rename, edit or remove, and "Remove" on a remote card was already wired to
    /// nothing.
    @Test func aRemoteCardOffersOnlyWhatTheProtocolCanDo() {
        #expect(WorkspaceMenu.items(isLocal: false, syncEnabled: true)
            == [.addTerminal, .addClaude])
    }

    @Test func everyItemButTheSeparatorIsTitled() {
        for item in local(syncEnabled: false) where item != .separator {
            #expect(!item.title.isEmpty)
        }
        #expect(WorkspaceMenuItem.addAgent.title == "Add Agent")
        #expect(WorkspaceMenuItem.addAgentWithArgs.title == "Add Agent with args")
        #expect(WorkspaceMenuItem.editWorkspace.title == "Edit workspace…")
    }

    /// An empty submenu with nothing in it reads as a broken menu, so it says where
    /// the agents come from instead.
    @Test func anEmptyAgentSubmenuSaysWhereAgentsComeFrom() {
        #expect(WorkspaceMenu.noAgents.contains("Settings"))
    }

    /// Both submenus are the agent list itself, so an agent added in Settings shows
    /// up in both without either being rebuilt.
    @Test func bothAgentSubmenusAreDrawnFromTheAgentList() {
        #expect(WorkspaceMenuItem.addAgent.isAgentSubmenu)
        #expect(WorkspaceMenuItem.addAgentWithArgs.isAgentSubmenu)
        #expect(!WorkspaceMenuItem.addTerminal.isAgentSubmenu)
    }
}

/// The card that draws the menu, rendered in the states the menu branches on, so a
/// construction failure in any of them surfaces here.
@MainActor
@Suite struct WorkspaceCardMenuRenderTests {
    private func card(agents: [AgentDefinition], isLocal: Bool) -> WorkspaceCardView {
        WorkspaceCardView(
            project: Project(url: URL(fileURLWithPath: "/tmp/proj")),
            collapsed: false,
            gitInfo: nil,
            runState: { _ in .running },
            needsAttention: { _ in false },
            syncEnabled: false,
            configChanged: false,
            isLocalOnly: { _ in false },
            agents: agents,
            onActivate: { _ in },
            onRestartTerminal: { _ in },
            onRenameTerminal: { _ in },
            onRemoveTerminal: { _ in },
            onCloseTerminal: { _ in },
            onOpenTerminal: {},
            onOpenClaude: {},
            onAddAgent: { _ in },
            onAddAgentWithArgs: { _ in },
            onAddWorkspace: {},
            onRemoveProject: {},
            onEditWorkspace: isLocal ? {} : nil,
            onToggleCollapsed: {},
            onEnableSync: {},
            onApplyConfig: {},
            processes: [],
            onProcessStart: { _ in },
            onProcessStop: { _ in },
            onProcessRestart: { _ in },
            onProcessKill: { _ in },
            onOpenProcessLog: { _ in },
            tests: [],
            onTestRun: { _ in },
            onTestRunAll: {},
            onOpenTestLog: { _ in })
    }

    @Test func theCardRendersWithAgentsAndWithout() {
        for agents in [[AgentDefinition.claude], []] {
            let view = card(agents: agents, isLocal: true)
            #expect(ImageRenderer(content: view.frame(width: 300)).nsImage != nil)
        }
    }

    @Test func theCardRendersAsARemoteCard() {
        #expect(ImageRenderer(content: card(agents: [], isLocal: false).frame(width: 300))
            .nsImage != nil)
    }
}
