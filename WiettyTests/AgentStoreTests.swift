import Testing
import Foundation
@testable import Wietty

/// The list of agents the workspace menu offers, which is a preference like the
/// ports and the bell sound: held on `ProjectStore`, persisted, and edited in the
/// Agents tab.
@MainActor
@Suite struct AgentStoreTests {
    private func store(_ defaults: UserDefaults) -> ProjectStore {
        ProjectStore(defaults: defaults, service: FakeTerminalService())
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    /// A fresh install offers Claude, so the menu is not empty before anyone has
    /// visited the Agents tab. It is the agent the menu offered when it was hardcoded.
    @Test func aFreshStoreOffersClaude() {
        #expect(store(freshDefaults()).agents.map(\.name) == ["Claude"])
    }

    @Test func anAddedAgentSurvivesARelaunch() {
        let defaults = freshDefaults()
        let first = store(defaults)
        first.addAgent(AgentDefinition(name: "Codex", command: "codex",
                                       defaultArguments: "--model o3"))
        let second = store(defaults)
        #expect(second.agents.map(\.name) == ["Claude", "Codex"])
        #expect(second.agents.last?.defaultArguments == "--model o3")
    }

    /// Deleting the last agent has to stick. Seeding on "the list is empty" rather
    /// than on "nothing has ever been stored" would put Claude back on the next
    /// launch, which reads as a delete that did not work.
    @Test func anEmptiedListIsNotReseeded() {
        let defaults = freshDefaults()
        let first = store(defaults)
        first.removeAgent(id: first.agents[0].id)
        #expect(first.agents.isEmpty)
        #expect(store(defaults).agents.isEmpty)
    }

    @Test func updatingAnAgentReplacesTheOneWithThatId() {
        let store = store(freshDefaults())
        var claude = store.agents[0]
        claude.defaultArguments = "--resume"
        store.updateAgent(claude)
        #expect(store.agents.count == 1)
        #expect(store.agents[0].defaultArguments == "--resume")
    }

    /// An update for an agent that has been deleted in the meantime adds nothing
    /// back: the edit form is on screen while the list can change under it.
    @Test func updatingAnUnknownAgentChangesNothing() {
        let store = store(freshDefaults())
        store.updateAgent(AgentDefinition(name: "Ghost", command: "ghost"))
        #expect(store.agents.map(\.name) == ["Claude"])
    }
}
