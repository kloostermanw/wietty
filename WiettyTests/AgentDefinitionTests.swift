import Testing
import Foundation
@testable import Wietty

/// What an agent entry is, and the one line it turns into.
///
/// A pure type with the composition rule on it, rather than the menu or the store
/// pasting a command and its arguments together: two callers do that ("Add Agent"
/// with the defaults, "Add Agent with args" with what was typed), and two copies of
/// a string join is two places for a missing space.
@Suite struct AgentDefinitionTests {
    private let codex = AgentDefinition(name: "Codex", command: "codex",
                                        defaultArguments: "--model o3")

    @Test func theDefaultArgumentsAreUsedWhenNoneAreGiven() {
        #expect(codex.launchCommand() == "codex --model o3")
    }

    @Test func anAgentWithoutDefaultArgumentsLaunchesBare() {
        #expect(AgentDefinition(name: "Claude", command: "claude").launchCommand() == "claude")
    }

    /// "Add Agent with args" hands over what the user typed, which replaces the
    /// defaults rather than appending to them: the field is pre-filled with the
    /// defaults, so appending would repeat every one of them.
    @Test func typedArgumentsReplaceTheDefaults() {
        #expect(codex.launchCommand(arguments: "--resume") == "codex --resume")
    }

    /// Clearing the pre-filled field is how a user asks for the bare command, so an
    /// empty string cannot fall back to the defaults it was just emptied of.
    @Test func clearedArgumentsLaunchTheCommandBare() {
        #expect(codex.launchCommand(arguments: "") == "codex")
        #expect(codex.launchCommand(arguments: "   ") == "codex")
    }

    /// Both halves are trimmed, because both are typed into a text field and a
    /// trailing space would be sent to the shell as part of the line.
    @Test func surroundingWhitespaceIsTrimmed() {
        let padded = AgentDefinition(name: " Codex ", command: "  codex  ",
                                     defaultArguments: "  --model o3  ")
        #expect(padded.launchCommand() == "codex --model o3")
    }

    /// An entry with no name has nothing to put in the menu, and one with no command
    /// has nothing to type into the shell. Save is disabled on both.
    @Test func anEntryNeedsBothANameAndACommand() {
        #expect(codex.isValid)
        #expect(!AgentDefinition(name: "", command: "codex").isValid)
        #expect(!AgentDefinition(name: "Codex", command: " ").isValid)
    }

    /// The seeded entry, which is the app's own hardcoded agent written down: a fresh
    /// install has to offer the thing the menu offered before this list existed.
    @Test func theSeededEntryIsClaude() {
        #expect(AgentDefinition.claude.name == "Claude")
        #expect(AgentDefinition.claude.launchCommand() == "claude")
    }
}
