import Foundation
import Testing
import WiettyShared
@testable import Wietty

/// Where a selected remote session goes when its row gets another one, and how a
/// snapshot's rows are read for it.
@Suite struct RemoteSelectionFollowTests {
    private let row = UUID()
    private let neighbour = UUID()

    private func replacement(for selected: String, from old: [RemoteRow], to new: [RemoteRow]) -> String? {
        RemoteSelectionFollow.replacement(for: selected, from: old, to: new)
    }

    @Test func theSameRowWithANewSessionIsFollowed() {
        let old = [RemoteRow(id: neighbour, sessionId: "n"), RemoteRow(id: row, sessionId: "old")]
        let new = [RemoteRow(id: neighbour, sessionId: "n"), RemoteRow(id: row, sessionId: "new")]
        #expect(replacement(for: "old", from: old, to: new) == "new")
    }

    /// The row is found by its id, not by its place: rows above it may have gone.
    @Test func theRowIsFoundByItsIdWhereverItIsNow() {
        let old = [RemoteRow(id: neighbour, sessionId: "n"), RemoteRow(id: row, sessionId: "old")]
        let new = [RemoteRow(id: row, sessionId: "new")]
        #expect(replacement(for: "old", from: old, to: new) == "new")
    }

    @Test func aRowThatIsGoneIsNotFollowed() {
        let old = [RemoteRow(id: neighbour, sessionId: "n"), RemoteRow(id: row, sessionId: "old")]
        #expect(replacement(for: "old", from: old, to: [RemoteRow(id: neighbour, sessionId: "n")]) == nil)
        #expect(replacement(for: "old", from: old, to: []) == nil)
    }

    @Test func anUnchangedSessionIsNotFollowed() {
        let rows = [RemoteRow(id: neighbour, sessionId: "n"), RemoteRow(id: row, sessionId: "old")]
        #expect(replacement(for: "old", from: rows, to: rows) == nil)
    }

    @Test func anotherRowChangingIsNotFollowed() {
        let old = [RemoteRow(id: neighbour, sessionId: "n"), RemoteRow(id: row, sessionId: "old")]
        let new = [RemoteRow(id: neighbour, sessionId: "n2"), RemoteRow(id: row, sessionId: "old")]
        #expect(replacement(for: "old", from: old, to: new) == nil)
    }

    /// A row with no session is one between two sessions, or one whose terminal is
    /// gone and not opened again. There is nothing to show for it.
    @Test func aRowWithNoSessionIsNotFollowed() {
        let old = [RemoteRow(id: row, sessionId: "old")]
        #expect(replacement(for: "old", from: old, to: [RemoteRow(id: row, sessionId: "")]) == nil)
    }

    /// Nothing says which row owned a session no old row carried.
    @Test func aSessionNoOldRowCarriedIsNotFollowed() {
        let old = [RemoteRow(id: row, sessionId: "other")]
        let new = [RemoteRow(id: row, sessionId: "new")]
        #expect(replacement(for: "old", from: old, to: new) == nil)
        #expect(replacement(for: "old", from: [], to: new) == nil)
    }

    /// An empty id is no session: rows without one must not be taken for its owner.
    @Test func anEmptySelectionIsNeverFollowed() {
        let old = [RemoteRow(id: row, sessionId: "")]
        let new = [RemoteRow(id: row, sessionId: "new")]
        #expect(replacement(for: "", from: old, to: new) == nil)
    }

    /// If the selected session is still carried, by whichever row, it has not been
    /// replaced and the selection stays.
    @Test func aSessionStillCarriedBySomeRowIsNotFollowed() {
        let old = [RemoteRow(id: row, sessionId: "old")]
        let new = [RemoteRow(id: row, sessionId: "new"), RemoteRow(id: neighbour, sessionId: "old")]
        #expect(replacement(for: "old", from: old, to: new) == nil)
    }

    /// The function sees one connection's rows at a time, so two connections cannot
    /// mix: a row with the same id on another Mac is in neither list. What keeps them
    /// apart is the caller, asserted in `PaneRouterTests`.
    @Test func rowsOfAnotherConnectionAreNeverInTheLists() {
        let mine = [RemoteRow(id: row, sessionId: "old")]
        let theirs = [RemoteRow(id: row, sessionId: "new")]
        #expect(replacement(for: "old", from: mine, to: mine) == nil)
        #expect(replacement(for: "old", from: theirs, to: theirs) == nil)
    }

    // MARK: - Rows of a snapshot

    @Test func everySessionOfEveryWorkspaceIsARowInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let workspaces = [
            RemoteWorkspace(id: UUID(), name: "one", sessions: [
                RemoteSession(id: a, sessionId: "s-a", label: "zsh"),
                RemoteSession(id: b, sessionId: "s-b", label: "claude", kind: .claude)
            ]),
            RemoteWorkspace(id: UUID(), name: "empty"),
            RemoteWorkspace(id: UUID(), name: "two", sessions: [
                RemoteSession(id: c, sessionId: "", label: "zsh")
            ])
        ]
        #expect(RemoteRow.rows(in: workspaces) == [
            RemoteRow(id: a, sessionId: "s-a", isAgent: false),
            RemoteRow(id: b, sessionId: "s-b", isAgent: true),
            RemoteRow(id: c, sessionId: "", isAgent: false)
        ])
    }

    // MARK: - The stopped screen

    /// The agent's wording for an agent row, the terminal's for a terminal row, and
    /// Restart for both.
    @Test func aSessionARowCarriesCanBeRestartedAndIsWordedByItsRow() {
        let rows = [RemoteRow(id: row, sessionId: "agent", isAgent: true),
                    RemoteRow(id: neighbour, sessionId: "shell", isAgent: false)]
        let agent = RemoteStoppedContent(sessionId: "agent", rows: rows)
        #expect(agent.isAgent)
        #expect(agent.canRestart)
        let shell = RemoteStoppedContent(sessionId: "shell", rows: rows)
        #expect(!shell.isAgent)
        #expect(shell.canRestart)
    }

    /// A session no row carries (its row was closed, or a stale id) can only be
    /// answered 404, so there is no Restart, and the wording is the terminal's.
    @Test func aSessionNoRowCarriesHasNoRestartAndTheTerminalWording() {
        let rows = [RemoteRow(id: row, sessionId: "agent", isAgent: true)]
        for content in [RemoteStoppedContent(sessionId: "gone", rows: rows),
                        RemoteStoppedContent(sessionId: "agent", rows: [])] {
            #expect(!content.isAgent)
            #expect(!content.canRestart)
        }
    }

    /// An empty id is no session: an agent row that carries none is not its row.
    @Test func anEmptySessionIsNoRowsSession() {
        let rows = [RemoteRow(id: row, sessionId: "", isAgent: true)]
        let content = RemoteStoppedContent(sessionId: "", rows: rows)
        #expect(!content.isAgent)
        #expect(!content.canRestart)
    }
}
