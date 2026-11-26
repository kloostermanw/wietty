import AppKit
import Foundation
import WiettyCore
import WiettyShared

/// The terminal this launch runs on, built once.
///
/// There is one terminal: a PTY Wietty spawns and owns, rendered by a
/// libghostty surface inside the main window. This type is what builds it, and it
/// stays a layer of its own rather than being folded into `GhosttyStack`, because
/// building the surface host is a step that can fail and the failure has to become
/// something the app can show rather than something a call site has to handle.
///
/// Everything downstream is handed the three protocol shaped pieces and never asks
/// what is behind them. `ghostty` is the exception, and it is there for the parts
/// of the UI only this terminal can serve: the pane needs the surface view, which
/// is not something a stream of bytes can answer.
@MainActor
struct TerminalStack {
    let service: any TerminalService
    let streamer: any ScreenStreaming
    let monitor: any SessionMonitoring
    let ghostty: GhosttyStack

    /// The Settings window's control over libghostty's `desktop-notifications`.
    ///
    /// Built here rather than reached for later because the host is private to
    /// `GhosttyStack`, and this is the one place that has it: the composition root
    /// is where the setting and the host it drives are introduced to each other.
    let desktopNotifications: DesktopNotificationSetting

    /// The Settings window's control over the terminal's colours, built here for the
    /// same reason `desktopNotifications` is: the host it writes through and reloads
    /// is private to `GhosttyStack`, and the composition root is the one place with it.
    let ghosttyColors: GhosttyColorSettings

    /// The host again, as the half that can hand out an `NSView`.
    ///
    /// Held here rather than on `GhosttyStack` because this is the last composition
    /// root that is certain to stay in the app: a view is the one thing a terminal
    /// has that only a window can use, and `GhosttyStack` is on its way to a target
    /// that never imports AppKit. Typed as both halves so no cast is needed; the one
    /// place that builds the concrete host is the one place that knows it is both.
    private let surfaces: any TerminalSurfaceViewing

    /// The view a session's surface renders into, for the pane. Nil for a session
    /// with no surface, which is every session on a stack that failed to build.
    ///
    /// The pane goes through here rather than holding the host itself: the host is
    /// the seam onto an unstable API, and one owner is the point of the seam.
    func surfaceView(for session: String) -> NSView? { surfaces.view(id: session) }

    /// The panes of terminals on other Macs, nil when there is no real surface host or
    /// no helper (a stack that failed to build, or one a test built on a fake host), or
    /// when no connection store was given.
    ///
    /// Built here because this is the one place that has the concrete host and the
    /// helper together. `TerminalQuitTeardown` closes them at quit, before the stack's
    /// own terminals, so no viewer surface outlives the teardown.
    let remotePanes: RemotePanes?

    /// What is wrong with the terminal, if anything. With nothing left to fall back
    /// to, this message is all a user whose libghostty failed to start ever gets,
    /// so it has to say what they can do about it.
    var setupError: String? { ghostty.setupError }

    /// - Parameter ghosttyHost: injected so tests can build this with no framework
    ///   and no Metal device. Nil on the real launch, where the real
    ///   `GhosttySurfaceHost` is created here and its failure becomes `setupError`.
    /// - Parameter helperPath: where the bundled `wietty-pty` is, defaulting to the
    ///   real lookup. The surfaces run it, so the app checks it here: nil, or a file
    ///   that is not executable, is a startup error. Injected for the same reason the
    ///   host is: with a working host and a real bundle nothing here can produce a
    ///   `setupError`, so a test of how this type carries one would have nothing to
    ///   carry.
    /// - Parameter localSocketPath: where the stack's `LocalStreamServer` listens.
    ///   Nil on the real launch: `LocalSocketPaths.server()`, a path that names this
    ///   process. Tests pass a path of their own, since they build several stacks in
    ///   the app's one process.
    /// - Parameter readDelay: how long a terminal waits for its pane's viewer before
    ///   its pty is read anyway. Shorter in tests, whose fake hosts have no pane.
    /// - Parameter remoteConnections: the connections a remote pane reads its
    ///   connection from at every attempt. Nil builds no `remotePanes`.
    init(ghosttyHost: (any TerminalSurfaceHosting & TerminalSurfaceViewing)? = nil,
         helperPath: String? = Self.helperPath(),
         localSocketPath: String? = nil,
         readDelay: TimeInterval = GhosttyService.unattachedReadDelay,
         remoteConnections: RemoteConnectionsStore? = nil) {
        let helper = helperPath.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        var socketFailure: TerminalError?
        let serverPath: String
        if let localSocketPath {
            serverPath = localSocketPath
        } else {
            do {
                serverPath = try LocalSocketPaths.server()
            } catch {
                serverPath = ""
                socketFailure = .localSocketFailed(String(describing: error))
            }
        }
        // A host that could not be built still yields a stack, so the app launches
        // and can explain itself rather than failing at every call site.
        let bridges = helper.map { PaneBridges(helperPath: $0, serverPath: serverPath) }
        let built = Self.buildHost(injected: ghosttyHost, bridges: bridges)
        // The failure REASON is passed in, not patched on afterwards, so the stack
        // installs a service that throws the same error `setupError` shows. Ordered
        // deliberately: a libghostty that will not start is the more fundamental
        // failure, and a build with that problem usually has the helper problem
        // too, so reporting the helper first would bury the real cause; the socket
        // comes last, since without a helper no surface would reach it anyway.
        let failure = built.error ?? (helper == nil ? .ghosttyHelperMissing : socketFailure)
        let stack = GhosttyStack(host: built.host,
                                 localSocketPath: serverPath,
                                 startupFailure: failure,
                                 readDelay: readDelay)
        ghostty = stack
        service = stack.service
        streamer = stack.hub
        monitor = stack.monitor
        desktopNotifications = DesktopNotificationSetting(host: built.host)
        ghosttyColors = GhosttyColorSettings(host: built.host)
        surfaces = built.host
        if let host = built.host as? GhosttySurfaceHost, let helper, let remoteConnections {
            remotePanes = RemotePanes(host: host, helperPath: helper, connections: remoteConnections)
        } else {
            remotePanes = nil
        }
        // Unconditional, because the sweep answers "is this socket abandoned" itself
        // (its owner's pid is gone) rather than trusting its caller to be the only
        // Wietty on the machine.
        LocalSocketPaths.sweep()
    }

    /// Where the bundled helper is. Nil means it is not in the bundle, which
    /// `init` turns into an actionable startup error.
    static func helperPath() -> String? {
        Bundle.main.url(forAuxiliaryExecutable: "wietty-pty")?.path
    }

    /// The surface host, and the reason it could not be created.
    ///
    /// Returns a host either way, because `GhosttyStack` takes a non-optional one:
    /// on failure that is `InertSurfaceHost`, which refuses every surface, and the
    /// error carries the reason. An injected host is used as given, which is how
    /// tests build this with no framework.
    ///
    /// The failure is a `TerminalError`, not a `String`, so the stack can install a
    /// service that throws the SAME error the user is shown. A string would only
    /// reach `setupError`, leaving every terminal action to throw whatever the
    /// stack's own guard branch chose.
    private static func buildHost(injected: (any TerminalSurfaceHosting & TerminalSurfaceViewing)?,
                                  bridges: PaneBridges?)
        -> (host: any TerminalSurfaceHosting & TerminalSurfaceViewing, error: TerminalError?) {
        if let injected { return (injected, nil) }
        do {
            return (try GhosttySurfaceHost(bridges: bridges), nil)
        } catch let error as SurfaceHostError {
            // `.initFailed` carries a message written for a user; anything else
            // falls back to its own description rather than to a placeholder, which
            // would throw away the one clue there is about what happened.
            let detail: String
            if case let .initFailed(message) = error {
                detail = message
            } else {
                detail = error.localizedDescription
            }
            return (InertSurfaceHost(), .ghosttyInitFailed(detail))
        } catch {
            return (InertSurfaceHost(), .ghosttyInitFailed(error.localizedDescription))
        }
    }
}
