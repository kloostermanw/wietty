import Foundation

/// Runs a workspace's freshness checks. Behind a protocol so `ProjectStore` can be
/// driven by a stub in tests, the same way `GitInfoProviding` fronts the real git
/// calls.
protocol FreshnessChecking: Sendable {
    /// Runs every configured check in `folder` and returns one result per check, in
    /// a stable name-sorted order so the marker's popover does not reshuffle between
    /// runs. An empty `checks` map returns no results, which is how a workspace with
    /// nothing configured shows no marker.
    func run(checks: [String: CheckConfig], in folder: URL) async -> [FreshnessResult]
}

/// Executes each check's command in a login shell rooted at the workspace
/// directory, the same invocation `PTYProcessLauncher` uses for a process or test
/// (`$SHELL -l -c`), so `PATH` and the user's tooling resolve. A non-zero exit
/// means the check is asking for action; the command's stdout becomes the result's
/// detail line.
struct FreshnessService: FreshnessChecking {
    private let runner: CommandRunning
    private let shell: String

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) {
        self.runner = runner
        self.shell = shell
    }

    func run(checks: [String: CheckConfig], in folder: URL) async -> [FreshnessResult] {
        checks.keys.sorted().map { name in
            let config = checks[name]!
            let result = runner.run(shell, ["-l", "-c", config.command], workingDirectory: folder)
            let message = config.message.isEmpty ? name : config.message
            return FreshnessResult(
                name: name,
                actionNeeded: result.status != 0,
                message: message,
                detail: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
