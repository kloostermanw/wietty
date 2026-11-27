import Foundation
import Observation

/// One restart of a session on another Mac that has been asked for, and until when a
/// second press for the same session is dropped.
///
/// The package's restart is not awaited and does not answer, so nothing says when it
/// is over. Three things do, well enough: the selection moves (a restart that worked
/// gave the row a new session and the selection followed it, which `RemoteRestartHolds`
/// is told), the connection's action error becomes something it was not at the press
/// (the request failed), or `duration` passes.
///
/// A failure that leaves the same error text as the one already shown at the press
/// cannot be told from no answer, so it is held for the whole `duration`.
struct RemoteRestartHold: Equatable {
    /// How long a press is held when nothing else ends it. Longer than a restart on
    /// the other Mac and its snapshot take, short enough that a request that got lost
    /// leaves the button usable again soon.
    static let duration: TimeInterval = 5

    let pressedAt: TimeInterval
    /// `RemoteWorkspaceStore.lastActionError` at the press.
    let errorAtPress: String?

    func isHeld(now: TimeInterval, lastActionError: String?) -> Bool {
        guard now - pressedAt < Self.duration else { return false }
        if let lastActionError, lastActionError != errorAtPress { return false }
        return true
    }
}

/// The remote restarts asked for and not answered yet, by session.
///
/// One object for the window, so a press on the pane's stopped screen and one on the
/// sidebar row of the same session hold each other. Observable, so the stopped
/// screen's button is drawn disabled while its session is held and enabled again when
/// the hold runs out.
@MainActor
@Observable
final class RemoteRestartHolds {
    private var holds: [RemoteSessionRef: RemoteRestartHold] = [:]
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let later: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// - Parameter now: a monotonic clock, in seconds.
    /// - Parameter later: runs its work on the main actor after that many seconds.
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         later: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
             Task { @MainActor in
                 try? await Task.sleep(for: .seconds(delay))
                 work()
             }
         }) {
        self.now = now
        self.later = later
    }

    /// Whether a restart of `session` is held.
    ///
    /// - Parameter lastActionError: the connection's store's, now.
    func isHeld(_ session: RemoteSessionRef, lastActionError: String?) -> Bool {
        holds[session]?.isHeld(now: now(), lastActionError: lastActionError) ?? false
    }

    /// A press of Restart for `session`. True when the request is to be sent, and the
    /// session is then held; false when it is held already.
    func press(_ session: RemoteSessionRef, lastActionError: String?) -> Bool {
        guard !isHeld(session, lastActionError: lastActionError) else { return false }
        let hold = RemoteRestartHold(pressedAt: now(), errorAtPress: lastActionError)
        holds[session] = hold
        // Removed when its time is up, which is what redraws a button that was drawn
        // disabled. Only this press: a later one for the same session has its own.
        later(RemoteRestartHold.duration) { [weak self] in
            guard let self, self.holds[session] == hold else { return }
            self.holds[session] = nil
        }
        return true
    }

    /// The pane shows something else now. Nothing is held past that: a restart that
    /// worked has moved the selection to the new session, and a user who went away
    /// and came back to a stopped screen must find its button live.
    func selectionMoved() {
        guard !holds.isEmpty else { return }
        holds.removeAll()
    }
}
