import Foundation

struct TerminalHandle: Equatable, Sendable {
    let sessionId: String
    let windowId: String
}

/// Every way any substrate can refuse to open a terminal. All three sets of
/// cases exist at all times, because the app is built with one substrate but
/// ships three, and a case that only one of them raises still has to be
/// describable when another is live.
enum TerminalError: LocalizedError, Equatable {
    /// Something one terminal action could not do, already worded for the user.
    case failed(String)
    case ghosttyInitFailed(String)
    case ghosttyHelperMissing

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        case .ghosttyInitFailed(let message):
            return "The internal terminal could not start: \(message)"
        case .ghosttyHelperMissing:
            return "The internal terminal helper is missing from the Wietty app bundle. Reinstall Wietty."
        }
    }
}

struct FocusResult: Equatable, Sendable {
    let found: Bool
    let jobName: String?
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
    let jobKnown: Bool

    init(found: Bool, jobName: String?, jobKnown: Bool = true) {
        self.found = found
        self.jobName = jobName
        self.jobKnown = jobKnown
    }
}

protocol TerminalService: Sendable {
    /// - Parameter badge: When non-nil, labels the terminal with this text,
    ///   independent of any other name it carries. Nil leaves the
    ///   label untouched.
    func open(folder: URL, existingWindowId: String?, command: String?, badge: String?) async throws -> TerminalHandle
    func focus(sessionId: String) async throws -> FocusResult
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

extension TerminalService {
    func discard(sessionId: String) async {}
    func stop(sessionId: String) async {}
}
