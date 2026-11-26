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
/// made again, on the next link's first `resize`, if the pane owned the grid when the
/// link was lost and that `resize` names the grid the pane claimed last (see
/// `linkEnded`). Never on bytes, a snapshot or a repaint, none of which reaches this
/// type, and never on any other `resize`.
///
/// **What the view shows.** One rule: while the pane is the owner the view fills the
/// pane, and otherwise it shows the grid in force. A claim the bridge accepted makes
/// the pane the owner at once (`claimAccepted`), so the view follows the window during
/// a drag without waiting for the round trip: the surface reflows by itself and the
/// pty catches up when the answer arrives. The one exception is an owner whose last
/// claim has been answered with a grid other than its own grid and that has no claim
/// waiting: the server's word stands, and the view shows that grid until the own grid
/// changes again. A surface that is not on display shows the grid in force whenever
/// the view is decided with no claim of its own outstanding, so the hidden surface
/// lays the child's output out for the grid the pty and the model are at; with a
/// claim outstanding the view is left as it is until the answer. Shown again, the
/// rule above applies.
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
    /// The grid last claimed, and when. Cleared by a refusal, so a later change may
    /// claim the same grid again.
    private var lastClaim: TerminalSize?
    private var lastClaimAt: UInt64?
    /// The grid of the last claim the bridge accepted, which a refusal leaves alone:
    /// what a lost link compares the next attach with.
    private var lastAccepted: TerminalSize?
    /// The own grid a debounced claim will carry when it fires.
    private var pending: TerminalSize?
    /// A `scheduleDebounce` has been returned and has not fired yet.
    private var debounceScheduled = false
    /// What the view was last told to show: `.some(nil)` the pane's own size.
    private var shown: TerminalSize?? = .some(nil)
    /// What the pane knew when its link was lost, kept until the next link's first
    /// `resize` decides whether it claims again. Nil while no link was lost since the
    /// last such decision.
    private var lostLink: LostLink?

    private struct LostLink {
        /// Whether the pane owned the grid when the link was lost.
        var owned: Bool
        /// The grid of the last claim it made that the bridge accepted, nil when it
        /// never made one. A refused claim does not count: it never left the pane.
        var lastClaim: TerminalSize?
    }

    package init(debounce: UInt64 = 50_000_000) {
        self.debounce = debounce
    }

    /// Whether the pane is the owner of the grid, as far as it can know.
    package var isOwner: Bool { ownership.isOwner }
    /// Claims accepted on this link and not answered yet.
    package var awaitingAnswers: Int { awaiting }

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
    ///
    /// The first `resize` after a lost link (the attach's, `own` false) decides what
    /// `linkEnded` left open: a pane that owned the grid and finds the grid it
    /// claimed last still in force claims again, its own grid on display and the grid
    /// in force off it (which keeps the grid without reflowing anything; shown again,
    /// it claims its own grid as an owner does). Any other pane claims nothing and
    /// shows the grid in force. A claim made since the loss (the user acted) is
    /// outstanding on the new link, so the pane is the owner here and that claim
    /// stands for itself: nothing more is claimed.
    package mutating func resizeReceived(_ grid: TerminalSize, own: Bool, now: UInt64) -> Action {
        ownership.resizeReceived(own: own)
        if own { awaiting = max(0, awaiting - 1) }
        inForce = grid
        // A claim waiting only because the window moved is for an owner; one that is
        // no longer the owner drops it (the iPad's rule too).
        if !ownership.isOwner { pending = nil }
        if let lost = lostLink {
            lostLink = nil
            if !ownership.isOwner, lost.owned, grid == lost.lastClaim {
                return claim(onDisplay ? ownGrid ?? grid : grid, now: now)
            }
        }
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
        lastAccepted = lastClaim
        return show(wanted())
    }

    /// The bridge refused the claim just returned (a grid out of range, a stopped
    /// bridge): nothing was counted, and a later change may claim again.
    package mutating func claimRefused() -> Action {
        lastClaim = nil
        return show(wanted())
    }

    /// The link ended and is being made again. A claim sent before may never be
    /// answered, so the count starts over, and a debounced claim waiting is dropped.
    /// Nothing is claimed here: another viewer may have claimed meanwhile, and only
    /// the next link's first `resize` can say so (`resizeReceived`). Until then the
    /// pane remembers whether it owned the grid and the grid it claimed last. A second
    /// loss before that `resize` keeps what the first remembered, unless the pane has
    /// claimed since (the user acted), in which case that claim is what it remembers.
    ///
    /// The view meanwhile: a pane that owned the grid keeps filling the pane and
    /// follows its window, as an owner with a claim outstanding does; any other shows
    /// the grid in force; a surface off display is given the grid in force.
    package mutating func linkEnded() -> Action {
        if ownership.isOwner || lostLink == nil {
            lostLink = LostLink(owned: ownership.isOwner, lastClaim: lastAccepted)
        }
        ownership = GridOwnership()
        awaiting = 0
        pending = nil
        return show(wanted())
    }

    /// The surface left the window: it keeps its last size and claims nothing, with
    /// one exception: once after a lost link, if it owned the grid and the next
    /// attach names the grid it claimed last, it claims the grid in force to keep it
    /// (see `resizeReceived`).
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
        if !onDisplay {
            // Hidden: the grid in force, once no claim of the pane's own is
            // outstanding. Until its answer the view is left as it is, so a hidden
            // surface is not sized to a grid the pty is about to leave and then again
            // to the answer's.
            if awaiting > 0 { return shown }
            if let inForce { return .some(inForce) }
        }
        if ownership.isOwner {
            if awaiting > 0 || pending != nil { return viewWhileClaimsOutstanding() }
            guard let inForce, let ownGrid, inForce != ownGrid else { return .some(nil) }
            return .some(inForce)
        }
        // Owned the grid when the link was lost, and the next link has not said yet
        // whether it still does: as an owner whose claim is outstanding.
        if lostLink?.owned == true { return viewWhileClaimsOutstanding() }
        // Not the owner: the grid in force, imposed even when it equals the own grid,
        // so a drag or a font change cannot let the surface reflow on its own for a
        // layout pass before an impose lands. Costs a margin of a few pixels at most.
        guard let inForce else { return shown }
        return .some(inForce)
    }

    /// What the view shows while the pane owns the grid with a claim unanswered or
    /// one waiting for the debounce. The one place where the two possible rules
    /// differ; the user decides between them.
    ///
    /// As built: the pane's own size (nil). The view follows the window at once, the
    /// surface reflows by itself, and the pty and the model catch up when the answer
    /// arrives. Cost: for that round trip (plus the debounce) the surface's grid and
    /// the model's differ, so cursor addressed output a program writes during a drag
    /// is laid out by the surface for a grid the program did not draw for.
    ///
    /// The spec's rule (section 7): keep showing the grid in force (`inForce`) and
    /// resize the view only when the server's answer comes back. Cost: the view lags
    /// the window by a round trip during every drag, with a margin or a clipped edge
    /// meanwhile.
    private func viewWhileClaimsOutstanding() -> TerminalSize?? {
        .some(nil)
    }

    private mutating func show(_ next: TerminalSize??) -> Action {
        guard let next, next != shown else { return .none }
        shown = next
        return .impose(next)
    }
}
