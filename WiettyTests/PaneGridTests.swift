import Foundation
import Testing
import WiettyCore
@testable import Wietty

private let ms: UInt64 = 1_000_000

private func grid(_ cols: Int, _ rows: Int) -> TerminalSize { TerminalSize(cols: cols, rows: rows) }

/// `GhosttyService.initialSize`, which is main actor isolated.
private let initial = TerminalSize(cols: 120, rows: 34)

/// `PaneGrid` driven as `OwnPaneGrid` drives it: a claim is handed to a bridge that
/// accepts it (or refuses, when told to), and what comes back from that is applied
/// too. Every claim, every grid imposed and every debounce asked for is recorded, and
/// a debounce fires only when the test says so.
private struct Pane {
    var model = PaneGrid()
    var now: UInt64 = 1_000 * ms
    var refuse = false
    private(set) var claims: [TerminalSize] = []
    private(set) var imposed: [TerminalSize?] = []
    private(set) var debounces: [UInt64] = []

    mutating func apply(_ action: PaneGrid.Action) {
        switch action {
        case .none: break
        case .claim(let grid):
            claims.append(grid)
            apply(refuse ? model.claimRefused() : model.claimAccepted())
        case .scheduleDebounce(let after): debounces.append(after)
        case .impose(let grid): imposed.append(grid)
        }
    }

    mutating func advance(_ nanoseconds: UInt64) { now += nanoseconds }

    mutating func show(_ own: TerminalSize) { apply(model.cameOnDisplay(own, now: now)) }
    mutating func own(_ own: TerminalSize) { apply(model.ownGridChanged(own, now: now)) }
    mutating func act() { apply(model.userActed(now: now)) }
    mutating func server(_ grid: TerminalSize, own: Bool) { apply(model.resizeReceived(grid, own: own)) }
    mutating func fire() { apply(model.debounceFired(now: now)) }
    mutating func ended() { apply(model.linkEnded(now: now)) }

    /// A pane that has opened at `own`, claimed it and been answered.
    static func owning(_ own: TerminalSize) -> Pane {
        var pane = Pane()
        pane.show(own)
        pane.server(own, own: true)
        return pane
    }

    /// A pane that owned `own` and then lost the grid to another viewer's `other`.
    static func notOwning(_ own: TerminalSize, imposed other: TerminalSize) -> Pane {
        var pane = owning(own)
        pane.server(other, own: false)
        return pane
    }
}

@Suite struct PaneGridTests {
    // MARK: Opening

    /// A new surface claims its own grid as soon as it knows it, at once, and is the
    /// owner from then on, so its view fills the pane.
    @Test func aNewSurfaceClaimsItsOwnGridOnceItKnowsIt() {
        var pane = Pane()
        pane.show(grid(100, 30))
        #expect(pane.claims == [grid(100, 30)])
        #expect(pane.model.isOwner)
        #expect(pane.imposed.isEmpty)
        #expect(pane.debounces.isEmpty)
    }

    /// Until it is on display it has no own grid and claims nothing; the grid the
    /// attach announces (the server's initial one) is imposed meanwhile.
    @Test func aSurfaceNotYetShownClaimsNothingAndShowsTheGridInForce() {
        var pane = Pane()
        pane.own(grid(100, 30))
        pane.server(initial, own: false)
        #expect(pane.claims.isEmpty)
        #expect(pane.imposed == [initial])
        pane.show(grid(100, 30))
        #expect(pane.claims == [grid(100, 30)])
        #expect(pane.imposed == [initial, nil])
    }

    /// The attach's `resize` (own false, the initial grid) arriving after the first
    /// claim went out is not the last word: the claim's answer is still to come.
    @Test func theAttachsResizeBeforeTheFirstAnswerImposesNothing() {
        var pane = Pane()
        pane.show(grid(100, 30))
        pane.server(initial, own: false)
        #expect(pane.model.isOwner)
        pane.server(grid(100, 30), own: true)
        #expect(pane.imposed.isEmpty)
        #expect(pane.claims == [grid(100, 30)])
    }

    // MARK: The owner follows its window

    /// While the owner, a change of the own grid claims: the first after a quiet
    /// period at once, then at most one per 50 ms, always the last value.
    @Test func anOwnersGridChangesAreDebouncedToTheLastValue() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(101, 30))
        #expect(pane.claims == [grid(100, 30), grid(101, 30)])

        pane.advance(10 * ms)
        pane.own(grid(102, 30))
        #expect(pane.debounces == [40 * ms])
        pane.advance(10 * ms)
        pane.own(grid(103, 30))
        pane.own(grid(104, 31))
        // One debounce for the lot, and nothing claimed before it fires.
        #expect(pane.debounces == [40 * ms])
        #expect(pane.claims.count == 2)

        pane.advance(30 * ms)
        pane.fire()
        #expect(pane.claims == [grid(100, 30), grid(101, 30), grid(104, 31)])

        // Within 50 ms of that claim: debounced again, from that claim.
        pane.advance(5 * ms)
        pane.own(grid(105, 31))
        #expect(pane.debounces == [40 * ms, 45 * ms])
        pane.advance(45 * ms)
        pane.fire()
        #expect(pane.claims.last == grid(105, 31))
        // The view followed the window throughout.
        #expect(pane.imposed.isEmpty)
    }

    /// A drag that comes back to the grid last claimed before the debounce fires
    /// claims nothing more.
    @Test func aDebouncedGridEqualToTheLastClaimIsNotClaimedAgain() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(101, 30))
        pane.advance(10 * ms)
        pane.own(grid(102, 30))
        pane.own(grid(101, 30))
        pane.advance(40 * ms)
        pane.fire()
        #expect(pane.claims == [grid(100, 30), grid(101, 30)])
    }

    /// Two claims in flight and the first answered: still the owner, and the stale
    /// answer imposes nothing; the second answer settles it.
    @Test func twoClaimsInFlightTheFirstAnsweredStaysOwner() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.advance(60 * ms)
        pane.own(grid(120, 30))
        #expect(pane.claims.suffix(2) == [grid(110, 30), grid(120, 30)])

        pane.server(grid(110, 30), own: true)
        #expect(pane.model.isOwner)
        #expect(pane.imposed.isEmpty)
        pane.server(grid(120, 30), own: true)
        #expect(pane.model.isOwner)
        #expect(pane.imposed.isEmpty)
    }

    /// The answer carries the grid in force, which need not be the claimed one. The
    /// pane acts on what the server says: with nothing else in flight, that grid is
    /// shown, and the next change of the own grid claims again.
    @Test func anAnswerCarryingAnotherGridIsShown() {
        var pane = Pane()
        pane.show(grid(100, 30))
        pane.server(grid(132, 30), own: true)
        #expect(pane.model.isOwner)
        #expect(pane.imposed == [grid(132, 30)])
        #expect(pane.claims == [grid(100, 30)])

        pane.advance(200 * ms)
        pane.own(grid(101, 30))
        #expect(pane.claims == [grid(100, 30), grid(101, 30)])
        #expect(pane.imposed == [grid(132, 30), nil])
    }

    // MARK: Another viewer

    /// A `resize` with `own` false for another grid imposes it; one with `own` true
    /// for the own grid imposes nothing more than the pane's own size.
    @Test func anotherViewersGridIsImposedAndOwnAnswerReturnsThePane() {
        var pane = Pane.owning(grid(100, 30))
        pane.server(grid(80, 24), own: false)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24)])
        pane.advance(100 * ms)
        pane.act()
        #expect(pane.claims.last == grid(100, 30))
        // Back to the pane's size as soon as the claim was taken.
        #expect(pane.imposed == [grid(80, 24), nil])
        pane.server(grid(100, 30), own: true)
        #expect(pane.imposed == [grid(80, 24), nil])
    }

    /// Another viewer's grid that happens to be the own grid is imposed all the same:
    /// a pane that is not the owner never lets its view follow the window, so a drag
    /// or a font change cannot reflow the surface before an impose lands.
    @Test func anotherViewersGridEqualToTheOwnGridIsImposedToo() {
        var pane = Pane.owning(grid(100, 30))
        pane.server(grid(100, 30), own: false)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(100, 30)])
        pane.own(grid(110, 30))
        #expect(pane.imposed == [grid(100, 30)])
    }

    /// The rule as built for the time a claim is outstanding: the view fills the pane
    /// from the moment the claim is accepted, before any answer, and stays so while
    /// answers are due or a debounced claim waits (`viewWhileClaimsOutstanding`).
    @Test func whileAClaimIsOutstandingTheViewFillsThePane() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.advance(200 * ms)
        pane.act()
        #expect(pane.model.awaitingAnswers == 1)
        #expect(pane.imposed == [grid(80, 24), nil])
        // Debounced claim waiting, answer still due: still the pane's size.
        pane.advance(10 * ms)
        pane.own(grid(120, 30))
        #expect(pane.debounces.count == 1)
        pane.server(grid(100, 30), own: true)
        #expect(pane.imposed == [grid(80, 24), nil])
    }

    /// Another viewer's claim handled between two of ours: not the last word, so not
    /// imposed; the pane stays the owner after its second answer.
    @Test func anotherViewersClaimBetweenTwoOfOursIsNotImposed() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.advance(60 * ms)
        pane.own(grid(120, 30))
        pane.server(grid(110, 30), own: true)
        pane.server(grid(80, 24), own: false)
        #expect(pane.model.isOwner)
        pane.server(grid(120, 30), own: true)
        #expect(pane.model.isOwner)
        #expect(pane.imposed.isEmpty)
    }

    /// The same claim handled after both of ours: it is the last word, and imposed.
    @Test func anotherViewersClaimAfterOursIsImposed() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.advance(60 * ms)
        pane.own(grid(120, 30))
        pane.server(grid(110, 30), own: true)
        pane.server(grid(120, 30), own: true)
        pane.server(grid(80, 24), own: false)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24)])
    }

    /// While not the owner, a change of the own grid claims nothing, and the
    /// imposed grid stays.
    @Test func notOwningAGridChangeClaimsNothing() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        let claims = pane.claims
        pane.advance(200 * ms)
        pane.own(grid(90, 28))
        pane.own(grid(70, 20))
        #expect(pane.claims == claims)
        #expect(pane.debounces.isEmpty)
        #expect(pane.imposed == [grid(80, 24)])
        // A pane that grows or shrinks onto the imposed grid keeps it imposed.
        pane.own(grid(80, 24))
        pane.own(grid(81, 24))
        #expect(pane.imposed == [grid(80, 24)])
    }

    /// While not the owner, a user action claims the own grid at once, even within
    /// 50 ms of the last claim; later actions, as the owner, claim nothing.
    @Test func notOwningAUserActionClaimsAtOnce() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.act()
        #expect(pane.claims == [grid(100, 30), grid(100, 30)])
        pane.act()
        pane.act()
        #expect(pane.claims.count == 2)
        #expect(pane.debounces.isEmpty)
    }

    /// A claim waiting for the debounce, only because the window moved, is dropped
    /// when another viewer takes the grid before it goes out.
    @Test func aDebouncedClaimIsDroppedWhenTheGridIsLost() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.server(grid(110, 30), own: true)
        pane.advance(10 * ms)
        pane.own(grid(120, 30))
        #expect(pane.debounces.count == 1)
        pane.server(grid(80, 24), own: false)
        pane.advance(40 * ms)
        pane.fire()
        #expect(pane.claims == [grid(100, 30), grid(110, 30)])
        #expect(pane.imposed == [grid(80, 24)])
    }

    // MARK: Never on what the server sends

    /// Receiving a `resize` never claims, whatever it says and however often: bytes,
    /// a snapshot and a repaint do not reach `PaneGrid` at all, and a `resize` is the
    /// one message that does.
    @Test func receivingAResizeNeverClaims() {
        for start in [Pane.owning(grid(100, 30)), Pane.notOwning(grid(100, 30), imposed: grid(80, 24)), Pane()] {
            var pane = start
            let claims = pane.claims
            for (size, own) in [(grid(90, 20), false), (grid(100, 30), true), (grid(1, 1), false),
                                (grid(100, 30), false), (grid(200, 60), true)] {
                pane.server(size, own: own)
            }
            #expect(pane.claims == claims)
            #expect(pane.debounces.isEmpty)
        }
    }

    // MARK: The bridge's answer and the link

    /// A claim the bridge refused is not counted: a pane that was not the owner
    /// stays not the owner and keeps the imposed grid, and the next action claims
    /// again.
    @Test func aRefusedClaimIsNotCounted() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.refuse = true
        pane.act()
        #expect(pane.claims.count == 2)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24)])
        pane.refuse = false
        pane.act()
        #expect(pane.claims.count == 3)
        #expect(pane.model.isOwner)
    }

    /// A refused first claim leaves the surface opening: its next own grid claims.
    @Test func aRefusedFirstClaimIsMadeAgain() {
        var pane = Pane()
        pane.refuse = true
        pane.show(grid(100, 30))
        pane.refuse = false
        pane.own(grid(101, 30))
        #expect(pane.claims == [grid(100, 30), grid(101, 30)])
        #expect(pane.model.isOwner)
    }

    /// The link ending with claims unanswered: the count starts over, and a pane
    /// that was the owner claims its own grid again at once.
    @Test func theLinkEndingWithClaimsUnansweredReclaimsForAnOwner() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.ended()
        #expect(pane.claims == [grid(100, 30), grid(110, 30), grid(110, 30)])
        // One claim on the new link, answered once: settled as the owner. Had the
        // count not started over, the unanswered claim of the old link would keep it
        // waiting for an answer forever.
        pane.server(grid(110, 30), own: false)
        pane.server(grid(110, 30), own: true)
        #expect(pane.model.isOwner)
        pane.server(grid(80, 24), own: false)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24)])
    }

    /// A pane that was not the owner claims nothing after the link ended, and shows
    /// what the next attach says.
    @Test func theLinkEndingClaimsNothingForAPaneThatWasNotTheOwner() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        let claims = pane.claims
        pane.ended()
        #expect(pane.claims == claims)
        pane.server(grid(90, 24), own: false)
        #expect(pane.imposed == [grid(80, 24), grid(90, 24)])
    }

    /// Without a reset on the end, a claim the old link never answered would leave
    /// the pane the owner forever, following its window while another viewer's grid
    /// is in force.
    @Test func afterTheLinkEndedAnotherViewersGridIsImposed() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        // The answer to that claim is lost with the link.
        pane.ended()
        pane.server(grid(110, 30), own: true)
        pane.server(grid(80, 24), own: false)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24)])
    }

    // MARK: Off display

    /// Off display: the surface keeps its size and claims nothing, not even on a
    /// user action or a pending debounce.
    @Test func offDisplayNothingIsClaimed() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.advance(10 * ms)
        pane.own(grid(120, 30))
        pane.model.wentOffDisplay()
        pane.own(grid(130, 30))
        pane.act()
        pane.advance(40 * ms)
        pane.fire()
        #expect(pane.claims == [grid(100, 30), grid(110, 30)])
    }

    /// Back on display with another own grid: the owner claims it.
    @Test func backOnDisplayTheOwnerClaimsADifferentGrid() {
        var pane = Pane.owning(grid(100, 30))
        pane.model.wentOffDisplay()
        pane.advance(200 * ms)
        pane.show(grid(90, 30))
        #expect(pane.claims == [grid(100, 30), grid(90, 30)])
        // And not when the grid in force is already its own grid.
        pane.server(grid(90, 30), own: true)
        pane.model.wentOffDisplay()
        pane.advance(200 * ms)
        pane.show(grid(90, 30))
        #expect(pane.claims.count == 2)
    }

    /// Back on display with another own grid, not the owner: nothing is claimed and
    /// the grid in force stays imposed.
    @Test func backOnDisplayANonOwnerClaimsNothing() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.model.wentOffDisplay()
        pane.advance(200 * ms)
        pane.show(grid(90, 30))
        #expect(pane.claims == [grid(100, 30)])
        #expect(pane.imposed == [grid(80, 24)])
    }

    /// Off display a `resize` is still taken: an imposed grid reaches the surface
    /// whether it is shown or not.
    @Test func offDisplayAnotherViewersGridIsStillImposed() {
        var pane = Pane.owning(grid(100, 30))
        pane.model.wentOffDisplay()
        pane.server(grid(80, 24), own: false)
        #expect(pane.imposed == [grid(80, 24)])
    }
}

/// What an `OwnPaneGrid` asked of its bridge and its host, in order. Main actor only.
@MainActor
private final class GridCalls {
    enum Call: Equatable {
        case claim(TerminalSize)
        case reset
        case impose(TerminalSize?)
    }
    private(set) var calls: [Call] = []
    var claims: [TerminalSize] {
        calls.compactMap { if case let .claim(grid) = $0 { grid } else { nil } }
    }
    func add(_ call: Call) { calls.append(call) }
}

/// `OwnPaneGrid`, the glue: a real main queue timer for the debounce, and the order in
/// which it talks to the bridge when the link was lost.
@MainActor
@Suite struct OwnPaneGridTests {
    private func grid(_ calls: GridCalls, debounce: UInt64 = 50_000_000) -> OwnPaneGrid {
        OwnPaneGrid(debounce: debounce,
                    claim: { size in calls.add(.claim(size)); return true },
                    resetClaims: { calls.add(.reset) },
                    impose: { size in calls.add(.impose(size)) })
    }

    private func eventually(within seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Two changes of the pane inside the debounce after a claim: the timer fires on
    /// the main queue and claims the last value, once.
    @Test func theDebounceTimerClaimsTheLastValue() async {
        let calls = GridCalls()
        let pane = grid(calls, debounce: 30_000_000)
        defer { pane.stop() }
        pane.paneChanged(ownGrid: TerminalSize(cols: 100, rows: 30))
        pane.paneChanged(ownGrid: TerminalSize(cols: 110, rows: 30))
        pane.paneChanged(ownGrid: TerminalSize(cols: 120, rows: 31))
        #expect(calls.claims == [TerminalSize(cols: 100, rows: 30)])
        #expect(await eventually { calls.claims.count == 2 })
        #expect(calls.claims == [TerminalSize(cols: 100, rows: 30), TerminalSize(cols: 120, rows: 31)])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(calls.claims.count == 2)
    }

    /// A stopped grid's timer claims nothing.
    @Test func aStoppedGridsTimerClaimsNothing() async {
        let calls = GridCalls()
        let pane = grid(calls, debounce: 20_000_000)
        pane.paneChanged(ownGrid: TerminalSize(cols: 100, rows: 30))
        pane.paneChanged(ownGrid: TerminalSize(cols: 110, rows: 30))
        pane.stop()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(calls.claims == [TerminalSize(cols: 100, rows: 30)])
    }

    /// When the link was lost the bridge drops what it held before the owner claims
    /// again, so the next link answers exactly the claims the fresh count holds.
    @Test func aLostLinkResetsTheBridgeBeforeClaimingAgain() {
        let calls = GridCalls()
        let pane = grid(calls)
        defer { pane.stop() }
        pane.paneChanged(ownGrid: TerminalSize(cols: 100, rows: 30))
        pane.resizeReceived(TerminalSize(cols: 100, rows: 30), own: true)
        pane.linkLost()
        #expect(calls.calls == [.claim(TerminalSize(cols: 100, rows: 30)), .reset,
                                .claim(TerminalSize(cols: 100, rows: 30))])
        #expect(pane.awaitingAnswers == 1)
    }
}
