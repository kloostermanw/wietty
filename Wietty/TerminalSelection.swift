import Foundation
import Observation
import WiettyCore

/// Which local terminal the window's pane is showing.
///
/// This used to live on `GhosttyService`, which meant the service decided what was on
/// screen as a side effect of being asked a question: `focus` answered whether a
/// session was alive and moved the Mac's pane while it was at it, so an agent calling
/// `select_process` or an iPad activating a row moved the pane on somebody else's
/// desk. The service answers now and the frontend decides.
///
/// Owned by `WiettyApp` rather than by `ContentView`, for the reason `PaneRouter` is:
/// the app menu can reach it and a view's `@State` cannot be reached from `commands`.
///
/// Everything that moves it arrives as a request, honoured synchronously, so with a
/// window open the pane moves exactly when it did before. With no frontend listening
/// the requests go nowhere and the terminals still run, which is what phase 5 needs.
@MainActor
@Observable
final class TerminalSelection {
    /// The session the pane shows, or nil for none.
    private(set) var current: String?

    /// Told after every change, with both sides of it.
    ///
    /// Wired by the app to two things that have to hear it in the same turn: the
    /// service, which records the outgoing terminal's screen while libghostty can
    /// still read it, and `PaneRouter`, which uncovers the pane when a local terminal
    /// comes into view.
    var onChanged: ((_ previous: String?, _ current: String?) -> Void)?

    /// Puts a terminal on screen, or empties the pane.
    ///
    /// Returns early when nothing moved, which is the guard `select` had: showing the
    /// terminal already on screen records no screens and tells nobody.
    func show(_ session: String?) {
        guard session != current else { return }
        let previous = current
        current = session
        onChanged?(previous, session)
    }
}
