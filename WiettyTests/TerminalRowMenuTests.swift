import Testing
import Foundation
@testable import Wietty

/// What a terminal or agent row's context menu offers, in what order. A pure type
/// rather than a `switch` inside the row's `.contextMenu`, for the same reason
/// `WorkspaceMenu` is: the set of things a menu offers is a fact about the app, and a
/// fact about the app belongs in CI rather than being checkable only by right clicking
/// a row.
@Suite struct TerminalRowMenuTests {
    @Test func aTerminalRowCanBeRenamed() {
        #expect(TerminalRowMenu.items(kind: .terminal)
            == [.rename, .copyId, .remove, .close])
    }

    /// An agent row runs `claude`, not an interactive shell to relabel, so it has no
    /// "Rename". Everything else is the same.
    @Test func anAgentRowCannotBeRenamed() {
        #expect(TerminalRowMenu.items(kind: .claude)
            == [.copyId, .remove, .close])
    }

    /// "Copy ID for agent" is the point of the change: every row offers it so another
    /// agent can be pointed at this session.
    @Test func everyRowKindOffersCopyId() {
        #expect(TerminalRowMenu.items(kind: .terminal).contains(.copyId))
        #expect(TerminalRowMenu.items(kind: .claude).contains(.copyId))
    }

    @Test func everyItemIsTitled() {
        for item in TerminalRowMenu.items(kind: .terminal) {
            #expect(!item.title.isEmpty)
        }
        #expect(TerminalRowMenuItem.copyId.title == "Copy ID for agent")
    }
}
