import Testing
import Foundation
@testable import Wietty

@Suite struct FreshnessServiceTests {
    private func service(_ handler: @escaping @Sendable (String, [String]) -> CommandResult) -> FreshnessService {
        FreshnessService(runner: FakeCommandRunner(handler: handler), shell: "/bin/zsh")
    }

    /// A check whose command exits non-zero is asking for action; its message and
    /// output are carried through to the result.
    @Test func nonZeroExitMeansActionNeeded() async {
        let svc = service { _, _ in CommandResult(stdout: "3 commits behind\n", stderr: "", status: 1) }
        let (results, _) = await svc.run(
            checks: ["behind": CheckConfig(command: "check", message: "git pull")],
            in: URL(fileURLWithPath: "/tmp/x"), cache: [:]
        )
        #expect(results.count == 1)
        #expect(results.first?.actionNeeded == true)
        #expect(results.first?.message == "git pull")
        #expect(results.first?.detail == "3 commits behind")
    }

    /// A check whose command exits zero is clean, so nothing is asked of the user.
    @Test func zeroExitMeansClean() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let (results, _) = await svc.run(
            checks: ["composer": CheckConfig(command: "check")],
            in: URL(fileURLWithPath: "/tmp/x"), cache: [:]
        )
        #expect(results.first?.actionNeeded == false)
    }

    /// With no message set, the check's name stands in, so the popover never shows a
    /// blank instruction.
    @Test func emptyMessageFallsBackToName() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 2) }
        let (results, _) = await svc.run(
            checks: ["npm": CheckConfig(command: "check")],
            in: URL(fileURLWithPath: "/tmp/x"), cache: [:]
        )
        #expect(results.first?.message == "npm")
    }

    /// The command runs in a login shell rooted at the workspace directory, the same
    /// invocation the process/test supervisors use, so PATH and tooling resolve.
    @Test func runsCommandInLoginShellAtWorkspace() async {
        let folder = URL(fileURLWithPath: "/tmp/ws")
        let captured = Captured()
        let svc = FreshnessService(
            runner: FakeCommandRunner(handler: { exe, args in
                captured.record(exe: exe, args: args)
                return CommandResult(stdout: "", stderr: "", status: 0)
            }),
            shell: "/bin/zsh"
        )
        _ = await svc.run(checks: ["c": CheckConfig(command: "git status")], in: folder, cache: [:])
        #expect(captured.exe == "/bin/zsh")
        #expect(captured.args == ["-l", "-c", "git status"])
    }

    /// Results are name-sorted, so the marker's popover keeps a stable order across
    /// runs rather than following the dictionary's hashing.
    @Test func resultsAreNameSorted() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let (results, _) = await svc.run(
            checks: [
                "npm": CheckConfig(command: "a"),
                "composer": CheckConfig(command: "b"),
                "migrations": CheckConfig(command: "c"),
            ],
            in: URL(fileURLWithPath: "/tmp/x"), cache: [:]
        )
        #expect(results.map(\.name) == ["composer", "migrations", "npm"])
    }

    @Test func emptyChecksReturnNoResults() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let (results, _) = await svc.run(checks: [:], in: URL(fileURLWithPath: "/tmp/x"), cache: [:])
        #expect(results.isEmpty)
    }

    /// A workspace needs the marker when any check is asking for action, and not
    /// when every check is clean or there are none.
    @Test func needsAttentionSummarizesActionable() {
        #expect([FreshnessResult]().needsAttention == false)
        #expect([FreshnessResult(name: "a", actionNeeded: false, message: "a")].needsAttention == false)
        #expect([
            FreshnessResult(name: "a", actionNeeded: false, message: "a"),
            FreshnessResult(name: "b", actionNeeded: true, message: "b"),
        ].needsAttention == true)
    }

    // MARK: - watch caching

    private func countingService(
        status: Int32 = 0,
        hash: @escaping @Sendable (URL) -> String?,
        onRun: @escaping @Sendable () -> Void
    ) -> FreshnessService {
        FreshnessService(
            runner: FakeCommandRunner(handler: { _, _ in
                onRun()
                return CommandResult(stdout: "", stderr: "", status: status)
            }),
            shell: "/bin/zsh",
            hashFile: hash
        )
    }

    /// A passing check with a `watch` file is not run again while the file's hash is
    /// unchanged: the cached result is reused.
    @Test func cachedResultSkipsCommandWhenWatchFileUnchanged() async {
        let runs = Counter()
        let svc = countingService(hash: { _ in "hash-1" }, onRun: { runs.bump() })
        let checks = ["composer": CheckConfig(command: "check", watch: "composer.lock")]
        let folder = URL(fileURLWithPath: "/tmp/x")

        let first = await svc.run(checks: checks, in: folder, cache: [:])
        let second = await svc.run(checks: checks, in: folder, cache: first.cache)

        #expect(runs.value == 1)
        #expect(second.results.first?.actionNeeded == false)
    }

    /// When the `watch` file's hash changes, the command runs again rather than
    /// serving the stale cached result.
    @Test func changedWatchFileReRunsCommand() async {
        let runs = Counter()
        let hash = Box("hash-1")
        let svc = countingService(hash: { _ in hash.value }, onRun: { runs.bump() })
        let checks = ["composer": CheckConfig(command: "check", watch: "composer.lock")]
        let folder = URL(fileURLWithPath: "/tmp/x")

        let first = await svc.run(checks: checks, in: folder, cache: [:])
        hash.value = "hash-2"
        _ = await svc.run(checks: checks, in: folder, cache: first.cache)

        #expect(runs.value == 2)
    }

    /// A failing `watch` check is never cached, so it keeps being re-run until it
    /// passes even while the file is unchanged.
    @Test func failingWatchCheckIsNotCached() async {
        let runs = Counter()
        let svc = countingService(status: 1, hash: { _ in "hash-1" }, onRun: { runs.bump() })
        let checks = ["composer": CheckConfig(command: "check", watch: "composer.lock")]
        let folder = URL(fileURLWithPath: "/tmp/x")

        let first = await svc.run(checks: checks, in: folder, cache: [:])
        _ = await svc.run(checks: checks, in: folder, cache: first.cache)

        #expect(first.cache.isEmpty)
        #expect(runs.value == 2)
    }

    /// Editing the check's command invalidates a cached passing result even when the
    /// `watch` file is unchanged, so a new script is not skipped as still-green.
    @Test func changedCommandBustsCache() async {
        let runs = Counter()
        let svc = countingService(hash: { _ in "hash-1" }, onRun: { runs.bump() })
        let folder = URL(fileURLWithPath: "/tmp/x")

        let first = await svc.run(
            checks: ["c": CheckConfig(command: "old", watch: "f")], in: folder, cache: [:])
        _ = await svc.run(
            checks: ["c": CheckConfig(command: "new", watch: "f")], in: folder, cache: first.cache)

        #expect(runs.value == 2)
    }

    /// A `watch` file that cannot be read hashes to nil, which cannot be cached, so
    /// the check runs on every tick like an ordinary one.
    @Test func unreadableWatchFileRunsEveryTick() async {
        let runs = Counter()
        let svc = countingService(hash: { _ in nil }, onRun: { runs.bump() })
        let checks = ["c": CheckConfig(command: "check", watch: "missing.lock")]
        let folder = URL(fileURLWithPath: "/tmp/x")

        let first = await svc.run(checks: checks, in: folder, cache: [:])
        _ = await svc.run(checks: checks, in: folder, cache: first.cache)

        #expect(first.cache.isEmpty)
        #expect(runs.value == 2)
    }

    /// The `watch` path is resolved against the workspace folder, so "src/composer.lock"
    /// hashes the file inside the workspace, not a bare or absolute path.
    @Test func watchFileResolvesRelativeToWorkspace() async {
        let captured = CapturedURL()
        let svc = FreshnessService(
            runner: FakeCommandRunner(handler: { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }),
            shell: "/bin/zsh",
            hashFile: { url in captured.record(url); return "h" }
        )
        _ = await svc.run(
            checks: ["c": CheckConfig(command: "x", watch: "src/composer.lock")],
            in: URL(fileURLWithPath: "/tmp/ws"), cache: [:]
        )
        #expect(captured.path == "/tmp/ws/src/composer.lock")
    }

    private final class Captured: @unchecked Sendable {
        var exe = ""
        var args: [String] = []
        func record(exe: String, args: [String]) { self.exe = exe; self.args = args }
    }

    private final class CapturedURL: @unchecked Sendable {
        var path = ""
        func record(_ url: URL) { path = url.path }
    }

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}
