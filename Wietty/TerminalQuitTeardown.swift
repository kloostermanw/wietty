import AppKit
import Foundation

/// Tears every terminal down when the app quits, because nothing else will.
///
/// A PTY the app spawned cannot outlive it usefully, and an object still alive at
/// exit gets no `deinit`, so without this the relay's socket file is left in the
/// temp directory for an hour until `GhosttyStack.clearStaleSockets` sweeps it, and
/// the shell only dies because its master happened to close. Synchronous delivery is
/// required, hence `queue: nil`: an `OperationQueue` hop may not run before the
/// process is gone.
///
/// A type of its own, owned by `TerminalStack`, rather than a few lines inside
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

    /// - Parameter service: held weakly, so an observer that outlives this cannot
    ///   resurrect the service and the terminals hanging off it.
    init(service: GhosttyService) {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak service] _ in
            MainActor.assumeIsolated { service?.closeAll() }
        }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
