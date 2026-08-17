import Foundation

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

    /// What is wrong with the terminal, if anything. With nothing left to fall back
    /// to, this message is all a user whose libghostty failed to start ever gets,
    /// so it has to say what they can do about it.
    var setupError: String? { ghostty.setupError }

    /// - Parameter ghosttyHost: injected so tests can build this with no framework
    ///   and no Metal device. Nil on the real launch, where the real
    ///   `GhosttySurfaceHost` is created here and its failure becomes `setupError`.
    /// - Parameter helperPath: where the bundled relay helper is, defaulting to the
    ///   real lookup. Injected for the same reason the host is: with a working host
    ///   and a real bundle nothing here can produce a `setupError`, so a test of how
    ///   this type carries one would have nothing to carry.
    init(ghosttyHost: (any TerminalSurfaceHosting)? = nil,
         helperPath: String? = Self.helperPath()) {
        // A host that could not be built still yields a stack, so the app launches
        // and can explain itself rather than failing at every call site.
        let built = Self.buildHost(injected: ghosttyHost)
        // The failure REASON is passed in, not patched on afterwards. Signalling a
        // libghostty failure by handing the stack `helperPath: nil` would make it
        // install the missing-helper service, so `setupError` would say libghostty
        // could not start while every terminal action threw "the helper is missing
        // from the app bundle. Reinstall Wietty." Two different wrong answers to
        // the same question is worse than either.
        let stack = GhosttyStack(host: built.host,
                                 helperPath: helperPath,
                                 hostFailure: built.error)
        ghostty = stack
        service = stack.service
        streamer = stack.hub
        monitor = stack.monitor
        desktopNotifications = DesktopNotificationSetting(host: built.host)
        ghosttyColors = GhosttyColorSettings(host: built.host)
        // Unconditional, because the sweep answers "is this socket abandoned" itself
        // rather than trusting its caller to be the only Wietty on the machine.
        stack.clearStaleSockets()
    }

    /// Where the bundled relay helper is. Nil means it is not in the bundle, which
    /// `GhosttyStack` turns into an actionable startup error.
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
    private static func buildHost(injected: (any TerminalSurfaceHosting)?)
        -> (host: any TerminalSurfaceHosting, error: TerminalError?) {
        if let injected { return (injected, nil) }
        do {
            return (try GhosttySurfaceHost(), nil)
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
