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
        let results = await svc.run(
            checks: ["behind": CheckConfig(command: "check", message: "git pull")],
            in: URL(fileURLWithPath: "/tmp/x")
        )
        #expect(results.count == 1)
        #expect(results.first?.actionNeeded == true)
        #expect(results.first?.message == "git pull")
        #expect(results.first?.detail == "3 commits behind")
    }

    /// A check whose command exits zero is clean, so nothing is asked of the user.
    @Test func zeroExitMeansClean() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let results = await svc.run(
            checks: ["composer": CheckConfig(command: "check")],
            in: URL(fileURLWithPath: "/tmp/x")
        )
        #expect(results.first?.actionNeeded == false)
    }

    /// With no message set, the check's name stands in, so the popover never shows a
    /// blank instruction.
    @Test func emptyMessageFallsBackToName() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 2) }
        let results = await svc.run(
            checks: ["npm": CheckConfig(command: "check")],
            in: URL(fileURLWithPath: "/tmp/x")
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
        _ = await svc.run(checks: ["c": CheckConfig(command: "git status")], in: folder)
        #expect(captured.exe == "/bin/zsh")
        #expect(captured.args == ["-l", "-c", "git status"])
    }

    /// Results are name-sorted, so the marker's popover keeps a stable order across
    /// runs rather than following the dictionary's hashing.
    @Test func resultsAreNameSorted() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let results = await svc.run(
            checks: [
                "npm": CheckConfig(command: "a"),
                "composer": CheckConfig(command: "b"),
                "migrations": CheckConfig(command: "c"),
            ],
            in: URL(fileURLWithPath: "/tmp/x")
        )
        #expect(results.map(\.name) == ["composer", "migrations", "npm"])
    }

    @Test func emptyChecksReturnNoResults() async {
        let svc = service { _, _ in CommandResult(stdout: "", stderr: "", status: 0) }
        let results = await svc.run(checks: [:], in: URL(fileURLWithPath: "/tmp/x"))
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

    private final class Captured: @unchecked Sendable {
        var exe = ""
        var args: [String] = []
        func record(exe: String, args: [String]) { self.exe = exe; self.args = args }
    }
}
