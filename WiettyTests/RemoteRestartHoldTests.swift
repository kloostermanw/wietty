import Foundation
import Testing
@testable import Wietty

/// When a second press of Restart for a session on another Mac is dropped, on a clock
/// the test moves.
@MainActor
@Suite struct RemoteRestartHoldTests {
    /// The clock and the delayed work of one `RemoteRestartHolds`.
    private final class Time {
        var now: TimeInterval = 100
        var scheduled: [(at: TimeInterval, work: @MainActor () -> Void)] = []

        /// Moves the clock and runs what came due, as the real delay would.
        @MainActor func advance(by seconds: TimeInterval) {
            now += seconds
            let due = scheduled.filter { $0.at <= now }
            scheduled.removeAll { $0.at <= now }
            due.forEach { $0.work() }
        }
    }

    private let connection = UUID()

    private func session(_ id: String, on connection: UUID? = nil) -> RemoteSessionRef {
        RemoteSessionRef(connectionId: connection ?? self.connection, sessionId: id)
    }

    private func holds(_ time: Time) -> RemoteRestartHolds {
        RemoteRestartHolds(now: { time.now },
                           later: { delay, work in time.scheduled.append((time.now + delay, work)) })
    }

    // MARK: - One hold

    @Test func aPressIsHeldUntilItsTimeIsUp() {
        let hold = RemoteRestartHold(pressedAt: 10, errorAtPress: nil)
        #expect(hold.isHeld(now: 10, lastActionError: nil))
        #expect(hold.isHeld(now: 10 + RemoteRestartHold.duration - 0.001, lastActionError: nil))
        #expect(!hold.isHeld(now: 10 + RemoteRestartHold.duration, lastActionError: nil))
        #expect(RemoteRestartHold.duration == 5)
    }

    /// The request failed: the store's error became something it was not.
    @Test func anErrorThatAppearsEndsTheHold() {
        let clean = RemoteRestartHold(pressedAt: 10, errorAtPress: nil)
        #expect(!clean.isHeld(now: 11, lastActionError: "Action failed (500)."))
        let stale = RemoteRestartHold(pressedAt: 10, errorAtPress: "Action failed (404).")
        #expect(!stale.isHeld(now: 11, lastActionError: "Action failed (500)."))
    }

    /// An error that was already there at the press says nothing about this request,
    /// and one that was cleared says an action worked, which is no reason to let a
    /// second request out before the selection has moved.
    @Test func anUnchangedOrClearedErrorDoesNotEndTheHold() {
        let stale = RemoteRestartHold(pressedAt: 10, errorAtPress: "Action failed (404).")
        #expect(stale.isHeld(now: 11, lastActionError: "Action failed (404)."))
        #expect(stale.isHeld(now: 11, lastActionError: nil))
    }

    // MARK: - The window's holds

    @Test func theFirstPressGoesOutAndTheSecondIsDropped() {
        let time = Time()
        let holds = holds(time)
        #expect(!holds.isHeld(session("s"), lastActionError: nil))
        #expect(holds.press(session("s"), lastActionError: nil))
        #expect(holds.isHeld(session("s"), lastActionError: nil))
        time.advance(by: 0.3)
        #expect(!holds.press(session("s"), lastActionError: nil))
        #expect(!holds.press(session("s"), lastActionError: nil))
    }

    /// A dropped press does not start the time over: the hold ends 5 seconds after
    /// the press that went out, however often the button was pressed since.
    @Test func aDroppedPressDoesNotExtendTheHold() {
        let time = Time()
        let holds = holds(time)
        #expect(holds.press(session("s"), lastActionError: nil))
        time.advance(by: 4)
        #expect(!holds.press(session("s"), lastActionError: nil))
        time.advance(by: 1)
        #expect(!holds.isHeld(session("s"), lastActionError: nil))
        #expect(holds.press(session("s"), lastActionError: nil))
    }

    @Test func anotherSessionIsNotHeld() {
        let time = Time()
        let holds = holds(time)
        #expect(holds.press(session("s"), lastActionError: nil))
        #expect(holds.press(session("t"), lastActionError: nil))
        // The same session id on another Mac is another session.
        #expect(holds.press(session("s", on: UUID()), lastActionError: nil))
        #expect(!holds.press(session("s"), lastActionError: nil))
    }

    @Test func aFailedRequestLetsTheNextPressOut() {
        let time = Time()
        let holds = holds(time)
        #expect(holds.press(session("s"), lastActionError: nil))
        time.advance(by: 0.2)
        #expect(!holds.isHeld(session("s"), lastActionError: "Action failed (500)."))
        #expect(holds.press(session("s"), lastActionError: "Action failed (500)."))
        // That press is held in turn, against the error it started with.
        #expect(!holds.press(session("s"), lastActionError: "Action failed (500)."))
    }

    @Test func aMovedSelectionLetsTheNextPressOut() {
        let time = Time()
        let holds = holds(time)
        #expect(holds.press(session("s"), lastActionError: nil))
        holds.selectionMoved()
        #expect(!holds.isHeld(session("s"), lastActionError: nil))
        #expect(holds.press(session("s"), lastActionError: nil))
    }

    /// The hold is removed when its time is up, not only read as over: that removal is
    /// what redraws a button drawn disabled. A later press of the same session is not
    /// removed by the earlier one's timer.
    @Test func theTimerOfAnEarlierPressDoesNotEndALaterOne() {
        let time = Time()
        let holds = holds(time)
        #expect(holds.press(session("s"), lastActionError: nil))
        time.advance(by: 1)
        holds.selectionMoved()
        #expect(holds.press(session("s"), lastActionError: nil))
        // The first press's timer comes due 4 seconds after the second press.
        time.advance(by: 4)
        #expect(holds.isHeld(session("s"), lastActionError: nil))
        time.advance(by: 1)
        #expect(!holds.isHeld(session("s"), lastActionError: nil))
    }
}
