import Foundation
import Testing
import WiettyShared
@testable import Wietty

/// When a pane of a terminal on another Mac makes its next link, and what it shows
/// meanwhile. Time is passed in, so every delay and the end of the automatic phase is
/// exact.
@Suite struct RemoteReconnectPolicyTests {
    typealias Policy = RemoteReconnectPolicy

    /// A policy that is live, as after its first snapshot.
    private func live() -> Policy {
        var policy = Policy()
        policy.snapshotDelivered()
        return policy
    }

    /// Loses the link each time the previous attempt was due, starting at `start`, and
    /// returns the delays the policy asked for.
    private func delays(_ policy: inout Policy, losses: Int, start: TimeInterval = 0) -> [TimeInterval] {
        var now = start
        var result: [TimeInterval] = []
        for _ in 0..<losses {
            guard case .attempt(let after) = policy.linkEnded(.connectionLost, now: now) else { break }
            result.append(after)
            now += after
        }
        return result
    }

    @Test func aNewPolicyIsConnecting() {
        #expect(Policy().state == .connecting)
    }

    @Test func theDelaysStartAtOnceAndDoubleToFiveSeconds() {
        var policy = live()
        #expect(delays(&policy, losses: 8) == [0, 0.25, 0.5, 1, 2, 4, 5, 5])
        #expect(policy.state == .reconnecting)
    }

    @Test func aLossBeforeTheFirstSnapshotIsCountedTheSameWay() {
        var policy = Policy()
        #expect(delays(&policy, losses: 4) == [0, 0.25, 0.5, 1])
        #expect(policy.state == .reconnecting)
    }

    @Test func anAttemptDueAtTwoMinutesIsMadeAndOneAfterIsNot() {
        var policy = live()
        #expect(policy.linkEnded(.connectionLost, now: 1000) == .attempt(after: 0))
        // Doubling up to the cap well before the end.
        _ = delays(&policy, losses: 7, start: 1001)
        // Due exactly at the end of the 2 minutes: made.
        #expect(policy.linkEnded(.connectionLost, now: 1115) == .attempt(after: 5))
        #expect(policy.state == .reconnecting)
        // Due 5 s after the end: not made, and only the button is left.
        #expect(policy.linkEnded(.connectionLost, now: 1120) == .none)
        #expect(policy.state == .waiting)
        // Nothing comes by itself from here.
        #expect(policy.linkEnded(.connectionLost, now: 1200) == .none)
        #expect(policy.state == .waiting)
    }

    @Test func theTwoMinutesCountFromTheLossThatLeftConnecting() {
        var policy = Policy()
        #expect(policy.linkEnded(.connectionLost, now: 50) == .attempt(after: 0))
        _ = delays(&policy, losses: 7, start: 50)
        #expect(policy.linkEnded(.connectionLost, now: 165) == .attempt(after: 5))
        #expect(policy.linkEnded(.connectionLost, now: 166) == .none)
        #expect(policy.state == .waiting)
    }

    @Test func theButtonWhileReconnectingAttemptsNowAndKeepsTheTwoMinutes() {
        var policy = live()
        _ = policy.linkEnded(.connectionLost, now: 0)
        _ = delays(&policy, losses: 6, start: 0)
        #expect(policy.reconnectPressed(now: 100) == .attempt(after: 0))
        #expect(policy.state == .reconnecting)
        // The doubling goes on from where it was, and the end is still at 120.
        #expect(policy.linkEnded(.connectionLost, now: 100) == .attempt(after: 5))
        #expect(policy.linkEnded(.connectionLost, now: 116) == .none)
        #expect(policy.state == .waiting)
    }

    @Test func theButtonWhileWaitingAttemptsNowAndStartsANewTwoMinutes() {
        var policy = live()
        _ = policy.linkEnded(.connectionLost, now: 0)
        #expect(policy.linkEnded(.connectionLost, now: 200) == .none)
        #expect(policy.state == .waiting)

        #expect(policy.reconnectPressed(now: 500) == .attempt(after: 0))
        #expect(policy.state == .reconnecting)
        // The press was the attempt at once; the doubling starts over after it.
        #expect(delays(&policy, losses: 3, start: 500) == [0.25, 0.5, 1])
        // The new 2 minutes run from the press.
        #expect(policy.linkEnded(.connectionLost, now: 614) == .attempt(after: 2))
        #expect(policy.linkEnded(.connectionLost, now: 616) == .attempt(after: 4))
        #expect(policy.linkEnded(.connectionLost, now: 620) == .none)
        #expect(policy.state == .waiting)
    }

    @Test func theButtonDoesNothingWhileConnectingOrLive() {
        var connecting = Policy()
        #expect(connecting.reconnectPressed(now: 0) == .none)
        #expect(connecting.state == .connecting)
        var policy = live()
        #expect(policy.reconnectPressed(now: 0) == .none)
        #expect(policy.state == .live)
    }

    @Test func aSnapshotMakesItLiveAndStartsTheCountOver() {
        var policy = live()
        _ = delays(&policy, losses: 5, start: 0)
        policy.snapshotDelivered()
        #expect(policy.state == .live)
        // At once again, and a fresh 2 minutes from this loss.
        #expect(policy.linkEnded(.connectionLost, now: 1000) == .attempt(after: 0))
        #expect(delays(&policy, losses: 3, start: 1000) == [0.25, 0.5, 1])
        #expect(policy.linkEnded(.connectionLost, now: 1115) == .attempt(after: 2))
        #expect(policy.linkEnded(.connectionLost, now: 1117) == .none)
        #expect(policy.state == .waiting)
    }

    @Test func aSnapshotAfterTheButtonInWaitingMakesItLive() {
        var policy = live()
        _ = policy.linkEnded(.connectionLost, now: 0)
        _ = policy.linkEnded(.connectionLost, now: 200)
        _ = policy.reconnectPressed(now: 300)
        policy.snapshotDelivered()
        #expect(policy.state == .live)
    }

    @Test func aSnapshotWhileWaitingChangesNothing() {
        var policy = live()
        _ = policy.linkEnded(.connectionLost, now: 0)
        _ = policy.linkEnded(.connectionLost, now: 200)
        policy.snapshotDelivered()
        #expect(policy.state == .waiting)
    }

    @Test func aSessionThatEndedIsFinal() {
        for start in [Policy(), live()] {
            var policy = start
            #expect(policy.linkEnded(.sessionEnded, now: 0) == .none)
            #expect(policy.state == .ended)
            #expect(policy.isFinal)
            #expect(policy.linkEnded(.connectionLost, now: 1) == .none)
            #expect(policy.reconnectPressed(now: 2) == .none)
            policy.snapshotDelivered()
            #expect(policy.state == .ended)
        }
        var reconnecting = live()
        _ = reconnecting.linkEnded(.connectionLost, now: 0)
        _ = reconnecting.linkEnded(.sessionEnded, now: 1)
        #expect(reconnecting.state == .ended)
    }

    @Test func aServerTooOldIsRefusedWithItsText() {
        var policy = Policy()
        #expect(policy.linkEnded(.serverTooOld, now: 0) == .none)
        #expect(policy.state == .refused("The other Mac runs an older Wietty. Update Wietty on that Mac."))
        #expect(policy.isFinal)
        #expect(policy.linkEnded(.connectionLost, now: 1) == .none)
        #expect(policy.reconnectPressed(now: 2) == .none)
        policy.snapshotDelivered()
        #expect(policy.state == .refused("The other Mac runs an older Wietty. Update Wietty on that Mac."))
    }

    @Test func aRefusalShowsTheServersMessageWithoutControlCharacters() {
        var policy = live()
        _ = policy.linkEnded(.connectionLost, now: 0)
        #expect(policy.linkEnded(.refused(code: "protocol", message: "too\u{1B}[2J new\u{07}"), now: 1) == .none)
        #expect(policy.state == .refused("too[2J new"))
        #expect(policy.linkEnded(.connectionLost, now: 2) == .none)
        #expect(policy.reconnectPressed(now: 3) == .none)
        #expect(policy.linkEnded(.sessionEnded, now: 4) == .none)
        #expect(policy.state == .refused("too[2J new"))
    }

    @Test func aRemovedConnectionIsRefused() {
        var policy = live()
        _ = policy.linkEnded(.connectionLost, now: 0)
        policy.connectionRemoved()
        #expect(policy.state == .refused("Connection removed"))
        #expect(policy.reconnectPressed(now: 1) == .none)
    }

    @Test func nothingLeavesAFinalStateForAnother() {
        var policy = Policy()
        _ = policy.linkEnded(.sessionEnded, now: 0)
        _ = policy.linkEnded(.serverTooOld, now: 1)
        policy.connectionRemoved()
        policy.failed("x")
        #expect(policy.state == .ended)
    }

    // MARK: The refusal's text (moved from `RemoteTerminalView`)

    /// A refusal's message comes from the other Mac and is shown on this one, so it
    /// must not carry anything that drives a terminal.
    @Test func anEscapeSequenceInARefusalComesOutAsPlainText() {
        #expect(Policy.printable("bad\u{1B}[2Jtoken\u{1B}]0;title\u{07}")
                == "bad[2Jtoken]0;title")
    }

    @Test func controlCharactersOfEveryRangeAreDropped() {
        #expect(Policy.printable("a\u{0}\r\n\u{7F}b\u{80}\u{9B}31mc\u{9F}")
                == "ab31mc")
    }

    @Test func ordinaryTextIsKept() {
        #expect(Policy.printable("Sessie é ✓ ¡ok!") == "Sessie é ✓ ¡ok!")
    }
}
