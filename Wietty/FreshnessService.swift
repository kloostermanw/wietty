import CryptoKit
import Foundation

/// One entry in a workspace's freshness cache: the result of a passing check kept
/// against the hash of its `watch` file, so a later tick can reuse the result
/// without running the command while the file is unchanged. `command` is stored too,
/// so editing the check's script invalidates a stale passing result.
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
    func run(checks: [String: CheckConfig], in folder: URL, cache: FreshnessCache)
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

    func run(checks: [String: CheckConfig], in folder: URL, cache: FreshnessCache)
        async -> (results: [FreshnessResult], cache: FreshnessCache) {
        var results: [FreshnessResult] = []
        var updated: FreshnessCache = [:]
        for name in checks.keys.sorted() {
            let config = checks[name]!

            // A check with a readable `watch` file caches its passing result against
            // the file's hash: while the hash (and the command) is unchanged, the
            // stored result is reused and the command is not run. A file that cannot
            // be hashed falls through to running every tick.
            if let watch = config.watch,
               let hash = hashFile(folder.appendingPathComponent(watch)) {
                if let cached = cache[name], cached.watchHash == hash, cached.command == config.command {
                    results.append(cached.result)
                    updated[name] = cached
                    continue
                }
                let result = execute(config, name: name, in: folder)
                results.append(result)
                // Only a passing run is remembered; a failing check keeps re-running
                // until it is fixed rather than sticking on a cached failure.
                if !result.actionNeeded {
                    updated[name] = FreshnessCacheEntry(watchHash: hash, command: config.command, result: result)
                }
                continue
            }

            results.append(execute(config, name: name, in: folder))
        }
        return (results, updated)
    }

    /// Runs one check's command and turns its exit code and output into a result.
    private func execute(_ config: CheckConfig, name: String, in folder: URL) -> FreshnessResult {
        let result = runner.run(shell, ["-l", "-c", config.command], workingDirectory: folder)
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
