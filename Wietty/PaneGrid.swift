import Foundation
import WiettyCore
import WiettyShared

/// Decides, for one surface, when the pane claims the grid. Pure: time and the
/// sending of a claim are injected.
///
/// The server is the only thing that resizes a terminal. A viewer says "I am active,
/// this is my grid" with a claim, and the server answers every claim with exactly one
/// `resize` whose `own` is true, carrying the grid in force (which need not be the
/// grid claimed). This decides when the own pane claims and what grid its view shows;
/// `OwnPaneGrid` carries the actions out.
///
/// **When it claims** (spec section 6): the first own grid of a new surface; a change
/// of the own grid while the pane is the owner, at most one claim per `debounce` and
/// always the last value (the first after a quiet period goes out at once); a user
/// action while the pane is not the owner; coming back on display with an own grid
/// other than the grid in force, if the owner; and once after the link was lost and
/// made again, if the pane was the owner before. Never on bytes, a snapshot, a
/// repaint or a `resize`: none of those reaches this type at all, and
/// `resizeReceived` never returns a claim.
///
/// **What the view shows.** One rule: while the pane is the owner the view fills the
/// pane, and otherwise it shows the grid in force. A claim the bridge accepted makes
/// the pane the owner at once (`claimAccepted`), so the view follows the window during
/// a drag without waiting for the round trip: the surface reflows by itself and the
/// pty catches up when the answer arrives. The one exception is an owner whose last
/// claim has been answered with a grid other than its own grid and that has no claim
/// waiting: the server's word stands, and the view shows that grid until the own grid
/// changes again.
///
/// **Ownership** is the package's `GridOwnership`: owner while a claim is unanswered
/// or when the last `resize` was its own. It is replaced when the link ends, since a
/// claim sent to a link that ended may never be answered. `awaiting` counts the same
/// unanswered claims for one other question, whether an answer is the last word: with
/// two claims in flight the first answer names a grid that is no longer this pane's,
/// and showing it would flicker the view in the middle of a drag.
package struct PaneGrid {
    package enum Action: Equatable {
        case none
        /// Send a claim of this grid now, and report back with `claimAccepted` or
        /// `claimRefused`, which is what counts it.
        case claim(TerminalSize)
        /// Call `debounceFired` after this many nanoseconds.
        case scheduleDebounce(after: UInt64)
        /// Show this grid in the view. Nil: the pane's own size.
        case impose(TerminalSize?)
    }

    private let debounce: UInt64
    private var ownership = GridOwnership()
    /// Claims accepted and not yet answered on this link.
    private var awaiting = 0
    /// The grid that fits the pane, as last told while on display.
    private var ownGrid: TerminalSize?
    /// The grid the server last announced.
    private var inForce: TerminalSize?
    /// Whether the surface is on display. A new surface is not until it is shown.
    private var onDisplay = false
    /// No claim has been accepted for this surface yet.
    private var opening = true
    /// The grid last claimed, and when.
    private var lastClaim: TerminalSize?
    private var lastClaimAt: UInt64?
    /// The own grid a debounced claim will carry when it fires.
    private var pending: TerminalSize?
    /// A `scheduleDebounce` has been returned and has not fired yet.
    private var debounceScheduled = false
    /// What the view was last told to show: `.some(nil)` the pane's own size.
    private var shown: TerminalSize?? = .some(nil)

    package init(debounce: UInt64 = 50_000_000) {
        self.debounce = debounce
    }

    /// Whether the pane is the owner of the grid, as far as it can know.
    package var isOwner: Bool { ownership.isOwner }

    /// The pane's own grid changed (window, sidebar, font size, scale).
    package mutating func ownGridChanged(_ grid: TerminalSize, now: UInt64) -> Action {
        guard onDisplay else { return .none }
        guard grid != ownGrid else { return .none }
        ownGrid = grid
        if opening, lastClaim == nil { return claim(grid, now: now) }
        guard ownership.isOwner else { return show(wanted()) }
        return claimDebounced(grid, now: now)
    }

    /// The user typed, clicked, pasted or dropped something in the pane.
    package mutating func userActed(now: UInt64) -> Action {
        guard onDisplay, !ownership.isOwner, let grid = ownGrid else { return .none }
        pending = nil
        return claim(grid, now: now)
    }

    /// The server said which grid is in force.
    package mutating func resizeReceived(_ grid: TerminalSize, own: Bool) -> Action {
        ownership.resizeReceived(own: own)
        if own { awaiting = max(0, awaiting - 1) }
        inForce = grid
        // A claim waiting only because the window moved is for an owner; one that is
        // no longer the owner drops it (the iPad's rule too).
        if !ownership.isOwner { pending = nil }
        return show(wanted())
    }

    /// The debounce interval ran out.
    package mutating func debounceFired(now: UInt64) -> Action {
        debounceScheduled = false
        guard let grid = pending else { return .none }
        pending = nil
        guard onDisplay, ownership.isOwner, grid != lastClaim else { return show(wanted()) }
        return claim(grid, now: now)
    }

    /// The bridge took the claim just returned: it counts now, and the pane owns the
    /// grid until the server says otherwise.
    package mutating func claimAccepted() -> Action {
        ownership.claimSent()
        awaiting += 1
        opening = false
        return show(wanted())
    }

    /// The bridge refused the claim just returned (a grid out of range, a stopped
    /// bridge): nothing was counted, and a later change may claim again.
    package mutating func claimRefused() -> Action {
        lastClaim = nil
        return show(wanted())
    }

    /// The link ended and is being made again. A claim sent before may never be
    /// answered, so the count starts over. An owner claims its own grid again, so it
    /// does not silently lose the grid to nobody; a pane that was not the owner shows
    /// what the next link's attach says.
    package mutating func linkEnded(now: UInt64) -> Action {
        let wasOwner = ownership.isOwner
        ownership = GridOwnership()
        awaiting = 0
        pending = nil
        guard wasOwner, let grid = ownGrid else { return .none }
        return claim(grid, now: now)
    }

    /// The surface left the window: it keeps its last size and claims nothing.
    package mutating func wentOffDisplay() {
        onDisplay = false
    }

    /// The surface is on display again, with this own grid. It claims only if it is
    /// the owner and the grid differs from the grid in force (or if it never claimed).
    package mutating func cameOnDisplay(_ grid: TerminalSize, now: UInt64) -> Action {
        onDisplay = true
        ownGrid = grid
        if opening, lastClaim == nil { return claim(grid, now: now) }
        guard ownership.isOwner else { return show(wanted()) }
        guard grid != inForce else { return show(wanted()) }
        return claimDebounced(grid, now: now)
    }

    // MARK: Internals

    /// A claim now, or the debounce: at most one per `debounce`, the last value.
    private mutating func claimDebounced(_ grid: TerminalSize, now: UInt64) -> Action {
        if debounceScheduled {
            pending = grid
            return .none
        }
        if let last = lastClaimAt, now &- last < debounce {
            pending = grid
            debounceScheduled = true
            return .scheduleDebounce(after: last &+ debounce &- now)
        }
        return claim(grid, now: now)
    }

    private mutating func claim(_ grid: TerminalSize, now: UInt64) -> Action {
        lastClaim = grid
        lastClaimAt = now
        return .claim(grid)
    }

    /// What the view should show now, by the rule in the type's doc.
    private func wanted() -> TerminalSize?? {
        if ownership.isOwner {
            // Answers still to come, or a claim waiting for the debounce: the pane's
            // own size, which is what those claims ask for.
            if awaiting > 0 || pending != nil { return .some(nil) }
            guard let inForce, let ownGrid, inForce != ownGrid else { return .some(nil) }
            return .some(inForce)
        }
        guard let inForce else { return shown }
        return .some(inForce == ownGrid ? nil : inForce)
    }

    private mutating func show(_ next: TerminalSize??) -> Action {
        guard let next, next != shown else { return .none }
        shown = next
        return .impose(next)
    }
}
