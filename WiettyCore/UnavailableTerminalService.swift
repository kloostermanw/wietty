import Foundation

/// Stands in when a substrate cannot work, so every terminal action that can fail
/// does so with the actionable setup message instead of appearing to do nothing.
///
/// Shared by `TmuxStack` and `GhosttyStack`, which have the same contract: always
/// construct, and report what is wrong through `setupError`. A stack that failed
/// to build its real service installs this, and the app still launches.
///
/// `stop` and `discard` are the two non-throwing actions in the protocol, so they
/// cannot surface the error and stay no-ops here. That is harmless: nothing ever
/// opens on this substrate (`open` throws), so there is no live session to stop or
/// discard, and both are reached only for a session this service handed out.
package struct UnavailableTerminalService: TerminalService {
    package let error: TerminalError
    package func open(folder: URL, existingWindowId: String?, command: String?,
              badge: String?) async throws -> TerminalHandle {
        throw error
    }
    package func probe(sessionId: String) async throws -> FocusResult { throw error }
    package func send(sessionId: String, text: String) async throws { throw error }
    package func close(sessionId: String) async throws { throw error }
    package func readOutput(sessionId: String, maxLines: Int) async throws -> String { throw error }
}

/// A monitor that never reports anything, for a stack with nothing to watch.
package struct InactiveMonitor: SessionMonitoring {
    package func start(onEvent: @escaping @MainActor (MonitorEvent) -> Void) {}
    package func stop() {}
}
