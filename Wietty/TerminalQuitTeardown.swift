import AppKit
import Foundation
import WiettyCore

/// Tears every terminal down when the app quits, because nothing else will, and
/// stops the local socket server. The panes of terminals on other Macs go first.
///
/// A PTY the app spawned cannot outlive it usefully, and an object still alive at
/// exit gets no `deinit`, so without this every pane's bridge socket and the server's
/// socket would be left in the temp directory until the next launch's
/// `LocalSocketPaths.sweep` found their owner gone, and the shell would only die
/// because its master happened to close. Synchronous delivery is required, hence
/// `queue: nil`: an `OperationQueue` hop may not run before the process is gone.
///
/// A type of its own, owned by `ServerRuntime`, rather than a few lines inside
/// `GhosttyStack`. Two reasons. `NSApplication` is the last thing keeping that stack
/// tied to AppKit, and it is on its way to a target that never imports it. And the
/// owner has to be something with a `deinit`, which `TerminalStack` is not: it is a
/// struct, so the token would have nowhere to be handed back from.
@MainActor
final class TerminalQuitTeardown {
    /// Held only so it can be removed: an observer left registered after this is
    /// gone is a token `NotificationCenter` keeps forever. `nonisolated(unsafe)`
    /// because a nonisolated `deinit` on a main actor type may only touch immutable
    /// state, and the token is an opaque `NSObjectProtocol` carrying no `Sendable`
    /// conformance; the only access from outside the main actor is the `deinit` that
    /// hands it straight back.
    private nonisolated(unsafe) let token: NSObjectProtocol

    /// - Parameter stack: held weakly, so an observer that outlives this cannot
    ///   resurrect the stack and the terminals hanging off it.
    /// - Parameter remotePanes: the panes of terminals on other Macs, held weakly for
    ///   the same reason. Closed first, while the surface host is certain to be
    ///   whole: each close stops its link and bridge (the helper exits as its socket
    ///   closes) and destroys its viewer surface.
    init(stack: GhosttyStack, remotePanes: RemotePanes? = nil) {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak stack, weak remotePanes] _ in
            MainActor.assumeIsolated {
                remotePanes?.closeAll()
                stack?.shutDown()
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
