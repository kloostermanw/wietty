import SwiftUI
import AppKit

/// What the terminal half of the main window has to draw.
///
/// Separated from the view so the decision can be asserted without AppKit, a
/// window, or a Metal device. There are only four answers and each has a
/// different cause: a substrate that could not be built at all, a selected
/// terminal that has a surface, one whose terminal has ended, and nothing
/// selected yet.
enum GhosttyPaneState: Equatable {
    /// libghostty or the bundled helper is missing, and no terminal on this
    /// substrate can ever work this launch.
    case unavailable(String)
    /// A selected session whose surface exists. The pane shows its view.
    case terminal
    /// A selected session whose terminal has ended, whether stopped from its row or
    /// because its shell exited. The surface still exists, but all it can show is
    /// libghostty's "Process exited" line, so the pane offers a restart instead
    /// (issue #70).
    case stopped
    /// Nothing to show. Either nothing is selected, or the selected session has
    /// no surface, which is the same thing as far as this view is concerned:
    /// there is no view to put in the window.
    case empty

    /// - Parameter setupError: `GhosttyStack.setupError`.
    /// - Parameter session: the selected session, mirrored from `GhosttyService`.
    /// - Parameter hasSurface: whether that session has a surface view.
    /// - Parameter exited: `ProjectStore.isSessionExited` for that session.
    static func resolve(setupError: String?, session: String?, hasSurface: Bool,
                        exited: Bool = false) -> GhosttyPaneState {
        // The setup error wins over everything: a stack that could not be built
        // has no surfaces, so a selection would only ever reach `.empty` and the
        // user would be told "no terminal selected" for a substrate that is
        // broken. The reason has to be the thing on screen.
        if let setupError { return .unavailable(setupError) }
        // No surface wins over exited: that is a row being closed, which has
        // nothing left to restart.
        guard session != nil, hasSurface else { return .empty }
        return exited ? .stopped : .terminal
    }
}

/// A local terminal in the main window's pane on the libghostty substrate.
///
/// Shows the selected terminal's surface and nothing else. One at a time is the
/// whole design: every surface stays alive and keeps reading, and this view only
/// decides which one is in the window's view hierarchy. That is how Ghostty's own
/// tabs behave, and it is why a terminal keeps running while another is on screen.
///
/// A terminal that has ended still has a surface, because `GhosttyService` keeps
/// it until the row is closed, but this does not show it. libghostty appends
/// "Process exited. Press any key to close the terminal." to that last screen, and
/// the key it asks for closes nothing useful here, so the pane shows a stopped
/// screen with Restart instead (issue #70). The surface stays alive behind it, off
/// screen, and the last screen it showed was recorded at the reap, so `readOutput`
/// and the MCP server still get that screen (though not its scrollback, which
/// only an on-screen surface can reach).
struct LocalTerminalView: View {
    let stack: GhosttyStack
    /// The selected session, mirrored into SwiftUI state by `ContentView` so a
    /// selection made in `GhosttyService` redraws this view.
    let session: String?
    /// `ProjectStore.isSessionExited` for `session`.
    var exited: Bool = false
    /// Whether the selected row is an agent, which only changes the wording of the
    /// stopped screen.
    var isAgent: Bool = false
    /// The stopped screen's Restart button. Wired by `ContentView` to
    /// `ProjectStore.restartTerminal`, which reopens the row with its own command;
    /// `GhosttyService.open` selects the replacement, so the pane leaves this
    /// screen on its own.
    var onRestart: () -> Void = {}

    var body: some View {
        Group {
            switch GhosttyPaneState.resolve(setupError: stack.setupError,
                                            session: session,
                                            hasSurface: surface != nil,
                                            exited: exited) {
            case .unavailable(let error):
                ContentUnavailableView {
                    Label("The internal terminal is unavailable", systemImage: "bolt.slash")
                } description: {
                    Text(error)
                }
            case .terminal:
                // Non-nil by construction: `resolve` only answers `.terminal`
                // when there is a surface. `EmptyView` rather than a second
                // placeholder, because a placeholder here would be unreachable
                // code claiming to be a state.
                if let surface { SurfaceContainer(surface: surface) } else { EmptyView() }
            case .stopped:
                ContentUnavailableView {
                    Label(isAgent ? "Agent stopped" : "Terminal stopped", systemImage: "terminal")
                } description: {
                    Text(isAgent ? "The agent has exited." : "The process has exited.")
                } actions: {
                    Button("Restart", action: onRestart)
                        .keyboardShortcut(.defaultAction)
                }
            case .empty:
                ContentUnavailableView {
                    Label("No terminal selected", systemImage: "terminal")
                } description: {
                    Text("Open a terminal in a workspace, or click one in the sidebar.")
                }
            }
        }
        // `maxHeight: .infinity` is load bearing, not cosmetic. Only one thing in
        // this window ever asks for the whole height on its own: `SurfaceContainer`
        // is an `NSViewRepresentable`, which has no ideal size and therefore takes
        // whatever it is offered, while both placeholders below ask for their
        // content. Without this the pane was as tall as its placeholder, which under
        // the previous `HSplitView` made the entire split view 240 points tall (this
        // minimum) and put it at the bottom of a window nearly a thousand points
        // high, because an AppKit view laid out short of its superview keeps its
        // bottom left origin. Measured then: `NSSplitView own=(0,0 1369x240)` with no
        // terminal open, `1369x1002` with one. The sidebar cannot carry the greed
        // instead: it sizes itself from its own content, which is what keeps the
        // workspace list from stretching.
        //
        // Both minimums come from `SidebarWidth` because the sidebar's ceiling and
        // the window's own minimum size are derived from them.
        .frame(minWidth: SidebarWidth.paneMinimum, minHeight: SidebarWidth.paneMinimumHeight,
               maxHeight: .infinity)
    }

    private var surface: NSView? {
        session.flatMap { stack.surfaceView(for: $0) }
    }
}

/// Puts an existing `NSView` into SwiftUI without owning it.
///
/// The view belongs to `GhosttySurfaceHost` for the terminal's whole life, so this
/// deliberately creates nothing and tears nothing down: it is a window into a view
/// someone else owns. `dismantleNSView` must not free the surface, or switching
/// rows would kill the terminal the user just left. The Task 1 spike proved a view
/// holding a live surface survives removal and re-addition, including into a
/// different `NSWindow`, with the shell still running and the scrollback intact.
struct SurfaceContainer: NSViewRepresentable {
    let surface: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        Self.attach(surface, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Only when the surface is not already where it belongs. SwiftUI calls
        // this for every unrelated redraw of the window, and re-parenting on each
        // one would take the first responder away from whatever the user is
        // typing into and make libghostty resend its metrics for nothing.
        guard surface.superview !== container else { return }
        Self.attach(surface, to: container)
    }

    /// Removes the surface from the container and frees NOTHING.
    ///
    /// The whole substrate rests on this: the surface and its view outlive every
    /// container SwiftUI builds around them. Freeing here would destroy the
    /// terminal the user just switched away from, which is the one failure this
    /// design exists to avoid. `GhosttyService.close` is what tears a terminal
    /// down, and only when the row is closed.
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    static func attach(_ surface: NSView, to container: NSView) {
        // Any previous occupant first, so a container that is being handed a
        // different terminal does not end up holding two.
        container.subviews.forEach { $0.removeFromSuperview() }
        surface.removeFromSuperview()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        focus(surface)
    }

    /// Makes the surface first responder, one main queue turn after it was
    /// attached.
    ///
    /// It has to be first responder or keys never reach the shell, and it does
    /// not become one by being added to a view. The hop is required rather than
    /// tidy: `makeNSView` runs before the container is in a window, so there is
    /// no window to make anything the first responder of yet, and doing it
    /// synchronously would silently do nothing on the very first attach.
    ///
    /// Only on an attach, never on every update, so this cannot steal the first
    /// responder from a rename dialog's text field while the user is typing in it.
    private static func focus(_ surface: NSView) {
        DispatchQueue.main.async {
            guard let window = surface.window, window.firstResponder !== surface else { return }
            window.makeFirstResponder(surface)
        }
    }
}
