import Foundation
import WiettyCore

/// Connects the pane's selection to everything that moves it and everything that has
/// to hear about it.
///
/// Three connections, and they used to be made inside `ContentView`'s `.task`. That
/// was wrong twice over. A request raised before the first view appeared was simply
/// dropped, where the code this replaced recovered by reading the service's selection
/// once as the view started. And wiring made inside a view's task is the one part of
/// this path no test could drive, so the three lines that join the halves together
/// were the three lines nothing checked.
///
/// Called while the app builds its object graph instead, before any scene exists.
@MainActor
enum TerminalSelectionWiring {
    /// - Parameter selection: what the pane reads.
    /// - Parameter terminals: raises a request when a terminal is opened, when the
    ///   displayed one is closed and another remains, and when everything is torn down.
    /// - Parameter store: raises `StoreEvent.showTerminal` when a row is asked for,
    ///   from a sidebar click, an agent's `select_process` or an iPad.
    /// - Parameter router: told when a local terminal comes into view, so whatever was
    ///   covering the pane is uncovered.
    static func connect(selection: TerminalSelection,
                        terminals: TerminalStack,
                        store: ProjectStore,
                        router: PaneRouter) {
        selection.onChanged = { [weak service = terminals.ghostty.ghosttyService] previous, current in
            // The outgoing terminal's screen, recorded while libghostty can still read
            // it. See `GhosttyService.displayedSessionChanged`.
            service?.displayedSessionChanged(from: previous, to: current)
            // A local terminal coming into view takes the pane back from whatever was
            // covering it, which is what makes opening or focusing one show it even
            // while a remote session, a log or settings is on screen. Closing one local
            // terminal while another remains also takes the pane, and this cannot tell
            // that apart from a click.
            //
            // This is not the whole of it: `show` returns early when the session is
            // already the displayed one, so re-activating the terminal the pane was
            // already showing arrives nowhere. `ProjectStore.activate` clears the
            // override itself for that reason.
            router.localSelectionChanged(to: current)
        }
        terminals.ghostty.displayRequests.handler = { session in selection.show(session) }
        store.events.subscribe { event in
            if case let .showTerminal(sessionId) = event { selection.show(sessionId) }
        }
    }
}
