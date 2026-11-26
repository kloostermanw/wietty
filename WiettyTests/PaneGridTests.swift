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
    mutating func server(_ grid: TerminalSize, own: Bool) { apply(model.resizeReceived(grid, own: own, now: now)) }
    mutating func fire() { apply(model.debounceFired(now: now)) }
    mutating func ended() { apply(model.linkEnded()) }
    mutating func hide() { model.wentOffDisplay() }

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
    /// one message that does. The one exception is the first `resize` after a lost
    /// link, below.
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

    /// Without a reset on the end, a claim the old link never answered would leave
    /// the pane the owner forever, following its window while another viewer's grid
    /// is in force.
    @Test func afterTheLinkEndedAnotherViewersGridIsImposed() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        // The answer to that claim is lost with the link, and the new attach says
        // another viewer's grid is in force.
        pane.ended()
        pane.server(grid(80, 24), own: false)
        #expect(!pane.model.isOwner)
        #expect(pane.model.awaitingAnswers == 0)
        #expect(pane.imposed == [grid(80, 24)])
    }

    // MARK: After a lost link

    /// The link ending claims nothing by itself, whoever owned the grid: what the pane
    /// does is decided by the first `resize` of the next link.
    @Test func theLinkEndingClaimsNothingByItself() {
        for start in [Pane.owning(grid(100, 30)), Pane.notOwning(grid(100, 30), imposed: grid(80, 24))] {
            var pane = start
            let claims = pane.claims
            pane.ended()
            #expect(pane.claims == claims)
            #expect(!pane.model.isOwner)
            #expect(pane.model.awaitingAnswers == 0)
        }
    }

    /// The owner, and the attach says the grid it claimed last is still in force:
    /// nobody took it meanwhile, so it claims its own grid again and stays the owner.
    /// Its view fills the pane throughout.
    @Test func anOwnerFindingItsGridClaimsAgain() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.ended()
        pane.server(grid(100, 30), own: false)
        #expect(pane.claims == [grid(100, 30), grid(100, 30)])
        #expect(pane.model.isOwner)
        pane.server(grid(100, 30), own: true)
        #expect(pane.model.isOwner)
        #expect(pane.imposed.isEmpty)
        // Only the first `resize` decides: later ones claim nothing.
        pane.server(grid(80, 24), own: false)
        #expect(pane.claims.count == 2)
        #expect(pane.imposed == [grid(80, 24)])
    }

    /// The owner, and the attach says another grid is in force: another viewer took it
    /// meanwhile. The pane claims nothing, is not the owner, and shows that grid, also
    /// when its own window changes.
    @Test func anOwnerFindingAnotherGridClaimsNothing() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.ended()
        pane.server(grid(80, 24), own: false)
        #expect(pane.claims == [grid(100, 30)])
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24)])
        pane.own(grid(110, 30))
        #expect(pane.claims == [grid(100, 30)])
        #expect(pane.imposed == [grid(80, 24)])
    }

    /// A pane that was not the owner claims nothing after the link ended, even when
    /// the attach names the grid it once claimed, and shows what the attach says.
    @Test func aPaneThatWasNotTheOwnerClaimsNothing() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        let claims = pane.claims
        pane.ended()
        pane.server(grid(100, 30), own: false)
        #expect(pane.claims == claims)
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24), grid(100, 30)])
    }

    /// A claim unanswered when the link was lost is the grid the pane claimed last.
    /// The attach names it when the server took the claim: the pane claims again. It
    /// names the grid before it when the claim was lost with the link: by the rule the
    /// pane cannot tell that from another viewer claiming that grid, and claims nothing.
    @Test func aClaimOutstandingAtTheLossIsTheGridClaimedLast() {
        var taken = Pane.owning(grid(100, 30))
        taken.advance(200 * ms)
        taken.own(grid(110, 30))
        taken.ended()
        taken.server(grid(110, 30), own: false)
        #expect(taken.claims == [grid(100, 30), grid(110, 30), grid(110, 30)])
        #expect(taken.model.isOwner)
        #expect(taken.imposed.isEmpty)

        var lost = Pane.owning(grid(100, 30))
        lost.advance(200 * ms)
        lost.own(grid(110, 30))
        lost.ended()
        lost.server(grid(100, 30), own: false)
        #expect(lost.claims == [grid(100, 30), grid(110, 30)])
        #expect(!lost.model.isOwner)
        #expect(lost.imposed == [grid(100, 30)])
    }

    /// A debounced claim waiting when the link was lost is dropped with the count and
    /// never goes out when the timer fires. An owner that finds its grid claims the
    /// grid that fits the pane at that moment instead, once; one that finds another
    /// grid claims nothing.
    @Test func aDebouncedClaimWaitingAtTheLossIsNeverSent() {
        var same = Pane.owning(grid(100, 30))
        same.advance(200 * ms)
        same.own(grid(110, 30))
        same.advance(10 * ms)
        same.own(grid(120, 30))
        #expect(same.debounces.count == 1)
        same.ended()
        same.server(grid(110, 30), own: false)
        same.advance(40 * ms)
        same.fire()
        #expect(same.claims == [grid(100, 30), grid(110, 30), grid(120, 30)])

        var other = Pane.owning(grid(100, 30))
        other.advance(200 * ms)
        other.own(grid(110, 30))
        other.advance(10 * ms)
        other.own(grid(120, 30))
        other.ended()
        other.server(grid(80, 24), own: false)
        other.advance(40 * ms)
        other.fire()
        #expect(other.claims == [grid(100, 30), grid(110, 30)])
        #expect(other.imposed == [grid(80, 24)])
    }

    /// The pane resized while the link was down. It claims nothing meanwhile, and an
    /// owner's view keeps following the window. On the attach the owner that finds its
    /// grid claims the grid that fits the pane now; one that finds another grid claims
    /// nothing and shows it.
    @Test func resizedWhileTheLinkWasDownAnOwner() {
        var same = Pane.owning(grid(100, 30))
        same.advance(200 * ms)
        same.ended()
        same.own(grid(120, 30))
        same.own(grid(125, 32))
        #expect(same.claims == [grid(100, 30)])
        #expect(same.debounces.isEmpty)
        #expect(same.imposed.isEmpty)
        same.server(grid(100, 30), own: false)
        #expect(same.claims == [grid(100, 30), grid(125, 32)])
        #expect(same.imposed.isEmpty)

        var other = Pane.owning(grid(100, 30))
        other.advance(200 * ms)
        other.ended()
        other.own(grid(120, 30))
        other.server(grid(80, 24), own: false)
        #expect(other.claims == [grid(100, 30)])
        #expect(other.imposed == [grid(80, 24)])
    }

    /// The same for a claim outstanding at the loss: the claim made again is the grid
    /// that fits the pane now.
    @Test func resizedWhileTheLinkWasDownWithAClaimOutstanding() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.ended()
        pane.own(grid(120, 30))
        pane.server(grid(110, 30), own: false)
        #expect(pane.claims == [grid(100, 30), grid(110, 30), grid(120, 30)])
        #expect(pane.imposed.isEmpty)
    }

    /// A pane that was not the owner and resized while the link was down: nothing is
    /// claimed, and the grid in force stays imposed, then the attach's.
    @Test func resizedWhileTheLinkWasDownNotTheOwner() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.ended()
        pane.own(grid(120, 30))
        #expect(pane.imposed == [grid(80, 24)])
        pane.server(grid(90, 24), own: false)
        #expect(pane.claims == [grid(100, 30)])
        #expect(pane.imposed == [grid(80, 24), grid(90, 24)])
    }

    /// The user acting right after the reconnect, having lost the grid by the rule:
    /// a key claims the own grid at once, as for any pane that is not the owner.
    @Test func theUserActingAfterTheReconnectTakesTheGrid() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.ended()
        pane.server(grid(80, 24), own: false)
        pane.act()
        #expect(pane.claims == [grid(100, 30), grid(100, 30)])
        #expect(pane.model.isOwner)
        #expect(pane.imposed == [grid(80, 24), nil])

        // Having kept the grid, acting claims nothing more.
        var kept = Pane.owning(grid(100, 30))
        kept.advance(200 * ms)
        kept.ended()
        kept.server(grid(100, 30), own: false)
        kept.act()
        #expect(kept.claims == [grid(100, 30), grid(100, 30)])
    }

    /// The user acting while the link is down claims at once; the claim goes to the
    /// next link, and with it outstanding the attach's `resize` is not the last word:
    /// nothing more is claimed and nothing imposed, whatever grid it names.
    @Test func theUserActingWhileTheLinkIsDownClaimsOnceForTheNextLink() {
        for attach in [grid(100, 30), grid(80, 24)] {
            var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
            pane.ended()
            pane.advance(200 * ms)
            pane.act()
            #expect(pane.claims == [grid(100, 30), grid(100, 30)])
            pane.server(attach, own: false)
            #expect(pane.claims.count == 2)
            #expect(pane.model.isOwner)
            pane.server(grid(100, 30), own: true)
            #expect(pane.model.isOwner)
            #expect(pane.imposed == [grid(80, 24), nil])
        }
    }

    /// A second loss before the first reconnect's `resize` arrived keeps what the
    /// pane knew at the first: an owner is still judged an owner on the attach that
    /// finally speaks, and a pane that was not stays not.
    @Test func aSecondLossBeforeTheAttachSpokeKeepsTheFirst() {
        var same = Pane.owning(grid(100, 30))
        same.advance(200 * ms)
        same.ended()
        same.ended()
        same.server(grid(100, 30), own: false)
        #expect(same.claims == [grid(100, 30), grid(100, 30)])
        #expect(same.model.isOwner)

        var other = Pane.owning(grid(100, 30))
        other.advance(200 * ms)
        other.ended()
        other.ended()
        other.server(grid(80, 24), own: false)
        #expect(other.claims == [grid(100, 30)])
        #expect(!other.model.isOwner)

        var never = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        never.ended()
        never.ended()
        never.server(grid(100, 30), own: false)
        #expect(never.claims == [grid(100, 30)])
        #expect(!never.model.isOwner)
    }

    /// A claim the user made between two losses is what the pane claimed last: the
    /// attach that names it finds the pane the owner.
    @Test func aClaimBetweenTwoLossesIsTheGridClaimedLast() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.ended()
        pane.advance(200 * ms)
        pane.own(grid(110, 30))
        pane.act()
        pane.ended()
        pane.server(grid(110, 30), own: false)
        #expect(pane.claims == [grid(100, 30), grid(110, 30), grid(110, 30)])
        #expect(pane.model.isOwner)
    }

    // MARK: After a lost link, off display

    /// Off display the surface is given the grid in force as soon as the link is
    /// lost. An owner that finds its grid on the attach keeps the grid by claiming the
    /// grid in force, which reflows nothing, rather than an own grid it last knew on
    /// display; shown again, it claims the grid that fits the pane, as an owner does.
    @Test func offDisplayAnOwnerFindingItsGridClaimsTheGridInForce() {
        var pane = Pane.owning(grid(100, 30))
        pane.advance(200 * ms)
        pane.ended()
        // Resized on display while the link was down, then hidden.
        pane.own(grid(120, 30))
        pane.hide()
        #expect(pane.imposed.isEmpty)
        pane.server(grid(100, 30), own: false)
        #expect(pane.claims == [grid(100, 30), grid(100, 30)])
        #expect(pane.model.isOwner)
        #expect(pane.imposed == [grid(100, 30)])
        pane.server(grid(100, 30), own: true)
        #expect(pane.imposed == [grid(100, 30)])

        pane.advance(200 * ms)
        pane.show(grid(120, 30))
        #expect(pane.claims == [grid(100, 30), grid(100, 30), grid(120, 30)])
        #expect(pane.imposed == [grid(100, 30), nil])
    }

    /// Hidden before the loss: the grid in force is imposed at the loss itself.
    @Test func offDisplayTheGridInForceIsImposedAtTheLoss() {
        var pane = Pane.owning(grid(100, 30))
        pane.hide()
        pane.ended()
        #expect(pane.imposed == [grid(100, 30)])
        pane.server(grid(100, 30), own: false)
        #expect(pane.claims == [grid(100, 30), grid(100, 30)])
        #expect(pane.imposed == [grid(100, 30)])
    }

    /// Off display, an owner finding another grid claims nothing and that grid is
    /// imposed, so the hidden surface follows it.
    @Test func offDisplayAnOwnerFindingAnotherGridClaimsNothing() {
        var pane = Pane.owning(grid(100, 30))
        pane.hide()
        pane.ended()
        pane.server(grid(80, 24), own: false)
        #expect(pane.claims == [grid(100, 30)])
        #expect(!pane.model.isOwner)
        #expect(pane.imposed == [grid(100, 30), grid(80, 24)])
    }

    /// Off display, a pane that was not the owner claims nothing and the attach's
    /// grid is imposed.
    @Test func offDisplayAPaneThatWasNotTheOwnerClaimsNothing() {
        var pane = Pane.notOwning(grid(100, 30), imposed: grid(80, 24))
        pane.hide()
        pane.ended()
        pane.server(grid(100, 30), own: false)
        #expect(pane.claims == [grid(100, 30)])
        #expect(pane.imposed == [grid(80, 24), grid(100, 30)])
    }

    /// Off display with a claim outstanding at the loss: the grid in force before it
    /// is imposed at the loss; an attach naming the claimed grid keeps the pane the
    /// owner at that grid, one naming the old grid leaves it not the owner.
    @Test func offDisplayWithAClaimOutstanding() {
        var taken = Pane.owning(grid(100, 30))
        taken.advance(200 * ms)
        taken.own(grid(110, 30))
        taken.hide()
        taken.ended()
        #expect(taken.imposed == [grid(100, 30)])
        taken.server(grid(110, 30), own: false)
        #expect(taken.claims == [grid(100, 30), grid(110, 30), grid(110, 30)])
        #expect(taken.model.isOwner)
        #expect(taken.imposed == [grid(100, 30), grid(110, 30)])

        var lost = Pane.owning(grid(100, 30))
        lost.advance(200 * ms)
        lost.own(grid(110, 30))
        lost.hide()
        lost.ended()
        lost.server(grid(100, 30), own: false)
        #expect(lost.claims == [grid(100, 30), grid(110, 30)])
        #expect(!lost.model.isOwner)
        #expect(lost.imposed == [grid(100, 30)])
    }

    /// Off display a user action claims nothing, after the reconnect as before it,
    /// and a second loss keeps what the first knew.
    @Test func offDisplayActingAndASecondLoss() {
        var pane = Pane.owning(grid(100, 30))
        pane.hide()
        pane.ended()
        pane.act()
        pane.ended()
        pane.server(grid(80, 24), own: false)
        pane.act()
        #expect(pane.claims == [grid(100, 30)])
        #expect(!pane.model.isOwner)

        var kept = Pane.owning(grid(100, 30))
        kept.hide()
        kept.ended()
        kept.ended()
        kept.server(grid(100, 30), own: false)
        #expect(kept.claims == [grid(100, 30), grid(100, 30)])
        #expect(kept.model.isOwner)
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

    /// When the link was lost the bridge drops what it held, and nothing is claimed
    /// until the next link's first `resize`: an owner that finds the grid it claimed
    /// last claims it again then.
    @Test func aLostLinkResetsTheBridgeAndClaimsOnlyOnTheAttach() {
        let calls = GridCalls()
        let pane = grid(calls)
        defer { pane.stop() }
        pane.paneChanged(ownGrid: TerminalSize(cols: 100, rows: 30))
        pane.resizeReceived(TerminalSize(cols: 100, rows: 30), own: true)
        pane.linkLost()
        #expect(calls.calls == [.claim(TerminalSize(cols: 100, rows: 30)), .reset])
        #expect(pane.awaitingAnswers == 0)
        pane.resizeReceived(TerminalSize(cols: 100, rows: 30), own: false)
        #expect(calls.calls == [.claim(TerminalSize(cols: 100, rows: 30)), .reset,
                                .claim(TerminalSize(cols: 100, rows: 30))])
        #expect(pane.awaitingAnswers == 1)
        #expect(pane.isOwner)
    }

    /// Another viewer's grid on the attach: nothing is claimed, the bridge keeps
    /// nothing for the new link, and that grid is shown.
    @Test func aLostLinkFindingAnotherGridClaimsNothing() {
        let calls = GridCalls()
        let pane = grid(calls)
        defer { pane.stop() }
        pane.paneChanged(ownGrid: TerminalSize(cols: 100, rows: 30))
        pane.resizeReceived(TerminalSize(cols: 100, rows: 30), own: true)
        pane.linkLost()
        pane.resizeReceived(TerminalSize(cols: 80, rows: 24), own: false)
        #expect(calls.calls == [.claim(TerminalSize(cols: 100, rows: 30)), .reset,
                                .impose(TerminalSize(cols: 80, rows: 24))])
        #expect(!pane.isOwner)
    }

    /// Off display: the grid in force is imposed at the loss, and the attach's grid
    /// when it differs, so the hidden surface is at the grid the pty and the model
    /// are at.
    @Test func offDisplayALostLinkImposesTheGridInForce() {
        let calls = GridCalls()
        let pane = grid(calls)
        defer { pane.stop() }
        pane.paneChanged(ownGrid: TerminalSize(cols: 100, rows: 30))
        pane.resizeReceived(TerminalSize(cols: 100, rows: 30), own: true)
        pane.paneChanged(ownGrid: nil)
        pane.linkLost()
        pane.resizeReceived(TerminalSize(cols: 80, rows: 24), own: false)
        #expect(calls.calls == [.claim(TerminalSize(cols: 100, rows: 30)), .reset,
                                .impose(TerminalSize(cols: 100, rows: 30)),
                                .impose(TerminalSize(cols: 80, rows: 24))])
    }
}
