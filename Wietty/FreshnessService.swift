import CryptoKit
import Foundation

/// One entry in a workspace's freshness cache: the result of a passing check kept
/// against the hash of its `watch` file, so a later tick can reuse the result
/// without running the command while the file is unchanged. The effective script
/// (the command with the workspace-wide `shell_init` prepended) is stored too, so
/// editing the command or a `shell_init` line invalidates a stale passing result.
struct FreshnessCacheEntry: Equatable, Sendable {
    var watchHash: String
    var command: String
    var result: FreshnessResult
}

/// A workspace's freshness cache, keyed by check name. Held in memory per workspace
/// by `ProjectStore`, passed into each run and replaced by the run's output, so it
/// lives for the session and is rebuilt from launch.
typealias FreshnessCache = [String: FreshnessCacheEntry]

/// Runs a workspace's freshness checks. Behind a protocol so `ProjectStore` can be
/// driven by a stub in tests, the same way `GitInfoProviding` fronts the real git
/// calls.
protocol FreshnessChecking: Sendable {
    /// Runs every configured check in `folder` and returns one result per check, in
    /// a stable name-sorted order so the marker's popover does not reshuffle between
    /// runs. An empty `checks` map returns no results, which is how a workspace with
    /// nothing configured shows no marker.
    ///
    /// `cache` carries the prior run's remembered passing results; the returned cache
    /// replaces it. A check with a `watch` file whose hash matches its cached entry
    /// is not run again, its stored result is reused.
    ///
    /// `shellInit` is the workspace-wide `shell_init`, prepended to each check's command
    /// the same way it is to a process or test command, so a check sees the same `PATH`
    /// and tooling the shell lines set up. A check has no per-check `shell_init` field;
    /// only these workspace-wide lines apply.
    ///
    /// `variables` are the per-project `WIETTY_*` values, injected into each check's
    /// environment exactly as the run-now path (`CheckSupervisor`) injects them, so a
    /// check reads the same values whichever path runs it. An unset reference expands
    /// to empty here; the run-now path opts into the same via `allow_empty_vars`.
    func run(checks: [String: CheckConfig], in folder: URL, cache: FreshnessCache,
             shellInit: [String], variables: [String: String])
        async -> (results: [FreshnessResult], cache: FreshnessCache)
}

/// Executes each check's command in a login shell rooted at the workspace
/// directory, the same invocation `PTYProcessLauncher` uses for a process or test
/// (`$SHELL -l -c`), so `PATH` and the user's tooling resolve. A non-zero exit
/// means the check is asking for action; the command's stdout becomes the result's
/// detail line.
struct FreshnessService: FreshnessChecking {
    private let runner: CommandRunning
    private let shell: String
    /// Hashes a `watch` file's contents, or returns `nil` when it cannot be read.
    /// Injected so tests can drive caching without touching the filesystem.
    private let hashFile: @Sendable (URL) -> String?

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        hashFile: @escaping @Sendable (URL) -> String? = FreshnessService.hashFileContents
    ) {
        self.runner = runner
        self.shell = shell
        self.hashFile = hashFile
    }

    func run(checks: [String: CheckConfig], in folder: URL, cache: FreshnessCache,
             shellInit: [String] = [], variables: [String: String] = [:])
        async -> (results: [FreshnessResult], cache: FreshnessCache) {
        var results: [FreshnessResult] = []
        var updated: FreshnessCache = [:]
        for name in checks.keys.sorted() {
            let config = checks[name]!
            // The effective script prepends the workspace-wide `shell_init`, so the
            // cache keys on what actually runs: editing either the command or a
            // `shell_init` line changes the script and busts a stale passing result.
            let script = ShellPrelude.script(lines: shellInit, command: config.command)

            // A check with a readable `watch` file caches its passing result against
            // the file's hash: while the hash (and the script) is unchanged, the
            // stored result is reused and the command is not run. A file that cannot
            // be hashed falls through to running every tick.
            if let watch = config.watch,
               let hash = hashFile(folder.appendingPathComponent(watch)) {
                if let cached = cache[name], cached.watchHash == hash, cached.command == script {
                    results.append(cached.result)
                    updated[name] = cached
                    continue
                }
                let result = execute(config, script: script, name: name, in: folder, variables: variables)
                results.append(result)
                // Only a passing run is remembered; a failing check keeps re-running
                // until it is fixed rather than sticking on a cached failure.
                if !result.actionNeeded {
                    updated[name] = FreshnessCacheEntry(watchHash: hash, command: script, result: result)
                }
                continue
            }

            results.append(execute(config, script: script, name: name, in: folder, variables: variables))
        }
        return (results, updated)
    }

    /// Runs one check's already-composed `script` and turns its exit code and output
    /// into a result. `script` is the command with the workspace-wide `shell_init`
    /// prepended, run in the same login shell a process or test uses. `variables` are
    /// injected into the environment so `$WIETTY_*` references resolve the same way
    /// they do on the run-now path.
    private func execute(_ config: CheckConfig, script: String, name: String, in folder: URL,
                         variables: [String: String]) -> FreshnessResult {
        let result = runner.run(shell, ["-l", "-c", script], workingDirectory: folder, environment: variables)
        return FreshnessResult(
            name: name,
            actionNeeded: result.status != 0,
            message: config.message.isEmpty ? name : config.message,
            detail: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The default hasher: SHA-256 of the file's contents, hex encoded. A file that
    /// cannot be read (missing, unreadable) hashes to `nil`, which the runner treats
    /// as "cannot cache", so the check runs.
    static func hashFileContents(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
