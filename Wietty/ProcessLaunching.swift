import Foundation

/// A handle to a launched OS process. Signals target the process group so
/// children (e.g. `node` under `npm`) receive them too.
protocol ProcessHandle: AnyObject, Sendable {
    func send(signal: Int32)
}

/// Launches a shell command and streams its output. The two callbacks are
/// delivered on the main actor so `ManagedProcess` can update observable state
/// directly. Injectable so the supervisor and processes can be tested with a
/// fake launcher.
protocol ProcessLaunching: Sendable {
    func launch(
        command: String,
        directory: URL,
        environment: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> ProcessHandle
}
