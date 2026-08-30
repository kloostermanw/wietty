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

    /// The upgrade case: a release that adds a field leaves every stored entry
    /// missing it. Decoding the list as a unit made that read as "nothing was ever
    /// stored", so the seed came back over the agents the user had configured.
    @Test func anEntryMissingAFieldStillLoads() {
        let defaults = freshDefaults()
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Codex","command":"codex"}]
        """
        defaults.set(Data(json.utf8), forKey: "wietty.agents")
        #expect(store(defaults).agents.map(\.name) == ["Codex"])
        #expect(store(defaults).agents[0].defaultArguments == "")
    }

    /// One unreadable entry costs that entry, not the whole list. An entry with no
    /// command could not start anything, so it is dropped rather than drawn as a menu
    /// item that does nothing.
    @Test func oneBadEntryDoesNotCostTheOthers() {
        let defaults = freshDefaults()
        let json = """
        [{"name":"Codex","command":"codex"},{"name":"Broken"},"nonsense"]
        """
        defaults.set(Data(json.utf8), forKey: "wietty.agents")
        #expect(store(defaults).agents.map(\.name) == ["Codex"])
    }

    /// An unreadable list is stored data, so it is not the seed either: putting
    /// Claude back would hand over an agent the user did not ask for, and the next
    /// edit writes it over whatever was there.
    @Test func anUnreadableListIsNotReseeded() {
        let defaults = freshDefaults()
        defaults.set(Data("not json at all".utf8), forKey: "wietty.agents")
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

    /// Dragging a row to reorder the menu is a real reorder that survives a relaunch,
    /// the same as adding one.
    @Test func movingAnAgentReordersAndPersists() {
        let defaults = freshDefaults()
        let first = store(defaults)
        first.addAgent(AgentDefinition(name: "Codex", command: "codex"))
        first.addAgent(AgentDefinition(name: "Aider", command: "aider"))
        // Claude, Codex, Aider -> move Aider (index 2) to the front.
        first.moveAgent(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(first.agents.map(\.name) == ["Aider", "Claude", "Codex"])
        #expect(store(defaults).agents.map(\.name) == ["Aider", "Claude", "Codex"])
    }
}
