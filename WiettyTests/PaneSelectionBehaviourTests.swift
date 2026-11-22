import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Which terminal the pane shows, through every path that can move it.
///
/// Written before selection left `GhosttyService`, against the behaviour as it was,
/// so the refactor has something to be measured against rather than described by. The
/// five cases are the ones a user would notice: clicking a row, an agent calling
/// `select_process`, a tap on the iPad, closing the terminal on screen, and closing
/// the last one.
///
/// `displayed` is the one line that knows how the app currently decides what is on
/// screen. Everything else is phrased in terms of what the user sees, so the assertions
/// survive the move.
@MainActor
@Suite struct PaneSelectionBehaviourTests {

    /// What the pane shows.
    private func displayed(_ stack: GhosttyStack) -> String? {
        stack.ghosttyService?.selected
    }

    /// When a screen is captured is behaviour, not an implementation detail: an
    /// off-screen surface reads as empty, so the outgoing terminal's screen has to be
    /// recorded while it is still the one on screen. `readOutput` and a remote
    /// viewer's first frame are what read it afterwards.
    @Test func movingThePaneRecordsBothScreensAtTheMoveNotAfter() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack(host: host, helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        let second = try await open(stack)
        #expect(displayed(stack) == second)

        let firstBefore = host.snapshotCalls[first] ?? 0
        let secondBefore = host.snapshotCalls[second] ?? 0
        _ = try await stack.service.focus(sessionId: first)

        // Both: the one leaving the pane and the one arriving.
        #expect((host.snapshotCalls[second] ?? 0) > secondBefore)
        #expect((host.snapshotCalls[first] ?? 0) > firstBefore)
    }

    /// Moving the pane to the terminal already on it records nothing, because nothing
    /// moved. `select` returns early on an unchanged selection.
    @Test func showingTheTerminalAlreadyOnScreenRecordsNothing() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack(host: host, helperPath: "/usr/bin/true")
        defer { stack.ghosttyService?.closeAll() }
        let only = try await open(stack)
        let before = host.snapshotCalls[only] ?? 0
        _ = try await stack.service.focus(sessionId: only)
        #expect((host.snapshotCalls[only] ?? 0) == before)
    }

    private func makeStack() -> GhosttyStack {
        GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true")
    }

    private func open(_ stack: GhosttyStack) async throws -> String {
        try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                     existingWindowId: nil, command: "sleep 5", badge: nil).sessionId
    }

    /// Opening a terminal puts it on screen. Every other case below starts from this.
    @Test func openingATerminalShowsIt() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        #expect(displayed(stack) == first)
        let second = try await open(stack)
        #expect(displayed(stack) == second)
    }

    /// Case 1: a local row click. `ProjectStore.activateThrowing` is what a click on a
    /// sidebar row calls, and the row it names ends up on screen.
    @Test func clickingALocalRowShowsThatTerminal() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        let second = try await open(stack)
        #expect(displayed(stack) == second)

        // Focus is the narrow call underneath the click: it is what moves the pane.
        let result = try await stack.service.focus(sessionId: first)
        #expect(result.found)
        #expect(displayed(stack) == first)
    }

    /// Case 2: an agent calling `select_process`, which reaches the same `focus`.
    @Test func selectProcessShowsThatTerminal() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        _ = try await open(stack)
        _ = try await stack.service.focus(sessionId: first)
        #expect(displayed(stack) == first)
    }

    /// Case 3: a tap on the iPad. `RemoteServer.activateOutcome` calls
    /// `ProjectStore.activateThrowing`, which reaches the same `focus`, and the
    /// serving Mac's own pane moves with it. `docs/remote-access.md` calls that the
    /// accepted price of one implementation of activation rather than two.
    @Test func aRemoteActivateShowsThatTerminalOnTheServingMac() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        _ = try await open(stack)
        _ = try await stack.service.focus(sessionId: first)
        #expect(displayed(stack) == first)
    }

    /// Case 4: closing the terminal on screen hands the pane to one that remains,
    /// rather than leaving it empty with terminals still open.
    @Test func closingTheDisplayedTerminalHandsThePaneOn() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        let second = try await open(stack)
        #expect(displayed(stack) == second)

        try await stack.service.close(sessionId: second)
        #expect(displayed(stack) == first)
    }

    /// Case 5: closing the last one empties the pane.
    @Test func closingTheLastTerminalEmptiesThePane() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let only = try await open(stack)
        #expect(displayed(stack) == only)

        try await stack.service.close(sessionId: only)
        #expect(displayed(stack) == nil)
    }

    /// Closing a terminal that is not the one on screen leaves the pane alone.
    @Test func closingAnUndisplayedTerminalLeavesThePaneAlone() async throws {
        let stack = makeStack()
        defer { stack.ghosttyService?.closeAll() }
        let first = try await open(stack)
        let second = try await open(stack)
        #expect(displayed(stack) == second)

        try await stack.service.close(sessionId: first)
        #expect(displayed(stack) == second)
    }
}
