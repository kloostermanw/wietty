import Foundation

package struct TerminalHandle: Equatable, Sendable {
    package let sessionId: String
    package let windowId: String

    /// Spelled out because the implicit memberwise one is internal and the fake
    /// services the store's tests run against are in the other module.
    package init(sessionId: String, windowId: String) {
        self.sessionId = sessionId
        self.windowId = windowId
    }
}

/// Every way any substrate can refuse to open a terminal. All three sets of
/// cases exist at all times, because the app is built with one substrate but
/// ships three, and a case that only one of them raises still has to be
/// describable when another is live.
package enum TerminalError: LocalizedError, Equatable {
    /// Something one terminal action could not do, already worded for the user.
    case failed(String)
    case ghosttyInitFailed(String)
    case ghosttyHelperMissing
    /// The socket the app's panes reach their terminals through could not be made
    /// or bound.
    case localSocketFailed(String)

    package var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        case .ghosttyInitFailed(let message):
            return "The internal terminal could not start: \(message)"
        case .ghosttyHelperMissing:
            return "The internal terminal helper is missing from the Wietty app bundle. Reinstall Wietty."
        case .localSocketFailed(let message):
            return "The internal terminal could not open its socket in the temporary directory: \(message)"
        }
    }
}

package struct FocusResult: Equatable, Sendable {
    package let found: Bool
    package let jobName: String?
    /// Whether `jobName` is an answer rather than the absence of one.
    ///
    /// A nil `jobName` used to mean both "the pane's foreground process is a
    /// bare shell" and "the query for it failed", and the caller acted on the
    /// first reading: `ProjectStore.activate` types `claude` into a Claude row
    /// whose agent is not running, so a `display-message` that failed while
    /// `select-window` succeeded submitted the literal text `claude` into a
    /// running agent as a prompt. False here means nothing is known and the
    /// caller must not act on the job, matching what `ProjectStore.runState`
    /// already does with a job it has never been told.
    package let jobKnown: Bool

    package init(found: Bool, jobName: String?, jobKnown: Bool = true) {
        self.found = found
        self.jobName = jobName
        self.jobKnown = jobKnown
    }
}

package protocol TerminalService: Sendable {
    func open(folder: URL, existingWindowId: String?, command: String?) async throws -> TerminalHandle
    /// Answers whether a session is alive and what it is running.
    ///
    /// A question, not an instruction. It was called `focus` and showed the session in
    /// the pane as it answered, so an MCP tool call or a tap on an iPad moved the
    /// Mac's pane as a side effect of asking. Showing a terminal is a request the
    /// frontend honours now; this only answers.
    func probe(sessionId: String) async throws -> FocusResult
    func send(sessionId: String, text: String) async throws
    func close(sessionId: String) async throws
    /// Returns the recent rendered screen contents for a session, most recent
    /// lines last, capped to `maxLines`. Throws if the session is not found.
    func readOutput(sessionId: String, maxLines: Int) async throws -> String

    /// Gives up whatever this service still holds under a session id that `focus`
    /// has just reported not found, before the caller opens a replacement for it.
    ///
    /// Nothing is closed and no signal is sent: the session is already gone, which
    /// is what the caller was just told. This is only about resources on this side
    /// of the boundary, so it cannot fail and does not throw.
    ///
    /// Defaulted to nothing, because on a substrate whose terminals live in another
    /// process there is nothing to hold: a service whose terminals live elsewhere
    /// answers not-found precisely
    /// because the session has left, taking everything with it. `GhosttyService`
    /// keeps a dead terminal's surface on purpose, so the last screen a command
    /// left stays readable, and this is what frees it at the one moment that screen
    /// is finished with.
    func discard(sessionId: String) async

    /// Stops a running terminal's child without retiring the row: the child is
    /// terminated and its last screen kept readable, exactly as when a command exits
    /// on its own, so the row can be reopened. Unlike `close`, the surface and the
    /// record survive, and unlike `discard` it acts on a live session. Cannot fail:
    /// stopping an already-exited or absent session is a no-op, and so is stopping on
    /// a substrate whose terminals live in another process.
    func stop(sessionId: String) async
}

package extension TerminalService {
    package func discard(sessionId: String) async {}
    package func stop(sessionId: String) async {}
}
