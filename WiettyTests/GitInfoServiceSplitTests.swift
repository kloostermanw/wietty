import Testing
import Foundation
@testable import Wietty

/// Scripts git/gh command output by matching on argument fragments.
private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
    var responses: [(match: String, result: CommandResult)] = []
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?,
             environment: [String: String]) -> CommandResult {
        let joined = arguments.joined(separator: " ")
        for r in responses where joined.contains(r.match) { return r.result }
        return CommandResult(stdout: "", stderr: "", status: 1)
    }
}
private func ok(_ s: String) -> CommandResult { CommandResult(stdout: s, stderr: "", status: 0) }

@Suite struct GitInfoServiceSplitTests {
    let folder = URL(fileURLWithPath: "/tmp/repo")

    @Test func gitSyncParsesAheadBehindAndIssue() async {
        let runner = ScriptedRunner()
        runner.responses = [
            ("rev-parse --is-inside-work-tree", ok("true")),
            ("rev-parse --abbrev-ref HEAD", ok("feature/issue-42")),
            ("rev-list --left-right --count @{upstream}...HEAD", ok("1\t2")),
            ("rev-parse --abbrev-ref @{upstream}", ok("origin/feature/issue-42")),
            ("symbolic-ref --short refs/remotes/origin/HEAD", ok("origin/main")),
            ("rev-list --left-right --count origin/main...HEAD", ok("3\t4")),
            ("remote get-url origin", ok("git@github.com:acme/widget.git")),
        ]
        let service = GitInfoService(runner: runner, gitPath: "/usr/bin/git", ghCandidates: [])
        let sync = await service.gitSync(for: folder)
        #expect(sync?.branch == "feature/issue-42")
        #expect(sync?.behind == 1 && sync?.ahead == 2)
        #expect(sync?.baseBehind == 3 && sync?.baseAhead == 4)
        #expect(sync?.issueNumber == 42)
        #expect(sync?.owner == "acme" && sync?.repo == "widget")
    }

    @Test func gitSyncReturnsNilForNonRepo() async {
        let runner = ScriptedRunner()
        runner.responses = [("rev-parse --is-inside-work-tree", ok("false"))]
        let service = GitInfoService(runner: runner, gitPath: "/usr/bin/git", ghCandidates: [])
        #expect(await service.gitSync(for: folder) == nil)
    }
}
