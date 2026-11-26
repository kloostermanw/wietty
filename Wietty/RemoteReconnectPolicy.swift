import Foundation
import WiettyShared

/// When the pane of a terminal on another Mac makes its next link, and what it shows
/// meanwhile. Pure: the time is passed in, and the answer is a step for the owner
/// (`RemotePane`) to carry out.
///
/// A lost link (`.connectionLost`) is made again by itself, at once the first time,
/// then after 0.25 s, doubling to 5 s, for 2 minutes counted from the loss that left
/// `connecting` or `live`. An attempt that would start after those 2 minutes is not
/// made: the pane waits for the button. The first snapshot of a link makes the pane
/// `live` and ends the count. The other ends are final: the session ended on the other
/// Mac, or the other Mac refused (too old, newer, or another refusal), and nothing is
/// tried again from there.
///
/// A wrong token arrives as `.connectionLost` (the server refuses the HTTP upgrade and
/// the package cannot see why), so it is retried like any lost connection.
struct RemoteReconnectPolicy: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The first link, before its snapshot: nothing of the terminal shown yet.
        case connecting
        /// A link delivered its snapshot.
        case live
        /// The link was lost and is being made again by itself.
        case reconnecting
        /// The automatic phase is over; only the button makes a link.
        case waiting
        /// The session ended on the other Mac. Final.
        case ended
        /// Refused, with the text to show. Final.
        case refused(String)
    }

    /// What the owner does next.
    enum Step: Equatable, Sendable {
        case none
        /// Make a new link after this many seconds (0: now).
        case attempt(after: TimeInterval)
    }

    /// How long links are made again by themselves after a loss.
    static let automaticPhase: TimeInterval = 120
    /// 0, 0.25, 0.5, 1, 2, 4, 5, 5, ...
    static let backoff = ReconnectBackoff(initial: 0.25, cap: 5)

    static let tooOldText = "The other Mac runs an older Wietty. Update Wietty on that Mac."
    static let connectionRemovedText = "Connection removed"

    private(set) var state: State = .connecting
    /// When the current automatic phase started (the loss that left `connecting` or
    /// `live`, or the button pressed in `waiting`).
    private var phaseStart: TimeInterval = 0
    /// Attempts made in the current automatic phase, which sets the next delay.
    private var attempts = 0

    init() {}

    /// Whether nothing is tried again: `ended` or `refused`.
    var isFinal: Bool {
        switch state {
        case .ended, .refused: true
        case .connecting, .live, .reconnecting, .waiting: false
        }
    }

    /// The current link ended for `reason` at `now`.
    mutating func linkEnded(_ reason: TerminalEndReason, now: TimeInterval) -> Step {
        guard !isFinal else { return .none }
        switch reason {
        case .connectionLost:
            return linkLost(now: now)
        case .sessionEnded:
            state = .ended
        case .serverTooOld:
            state = .refused(Self.tooOldText)
        case .refused(_, let message):
            state = .refused(Self.printable(message))
        }
        return .none
    }

    /// The current link delivered its first snapshot.
    mutating func snapshotDelivered() {
        switch state {
        case .connecting, .reconnecting:
            state = .live
            attempts = 0
        case .live, .waiting, .ended, .refused:
            // In `waiting` no link is out, so nothing can have delivered.
            break
        }
    }

    /// The reconnect button. In `reconnecting` an attempt now, with the 2 minutes still
    /// running; in `waiting` an attempt now and a new 2 minutes from `now`. Nothing in
    /// any other state.
    mutating func reconnectPressed(now: TimeInterval) -> Step {
        switch state {
        case .reconnecting:
            return .attempt(after: 0)
        case .waiting:
            state = .reconnecting
            phaseStart = now
            // The press is the attempt at once; the next loss waits the first delay.
            attempts = 1
            return .attempt(after: 0)
        case .connecting, .live, .ended, .refused:
            return .none
        }
    }

    /// The connection is gone from the store, so no link can be made. Final.
    mutating func connectionRemoved() {
        failed(Self.connectionRemovedText)
    }

    /// The pane cannot show the terminal at all (no surface or bridge could be made).
    /// Final.
    mutating func failed(_ message: String) {
        guard !isFinal else { return }
        state = .refused(message)
    }

    private mutating func linkLost(now: TimeInterval) -> Step {
        switch state {
        case .connecting, .live:
            phaseStart = now
            attempts = 0
        case .reconnecting:
            break
        case .waiting, .ended, .refused:
            // No link is out in `waiting`: a late end changes nothing.
            return .none
        }
        let delay = Self.backoff.delay(forAttempt: attempts)
        guard now + delay <= phaseStart + Self.automaticPhase else {
            state = .waiting
            return .none
        }
        attempts += 1
        state = .reconnecting
        return .attempt(after: delay)
    }

    /// A refusal's text as plain text: it comes from the network, so its control
    /// characters (C0, DEL and C1) are dropped rather than shown or let through to
    /// anything that interprets them. What is left of an escape sequence is shown as
    /// the characters it was made of.
    nonisolated static func printable(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
        }))
    }
}
