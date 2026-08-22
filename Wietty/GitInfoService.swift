import Foundation
import CryptoKit

protocol GitInfoProviding: Sendable {
    func gitSync(for folder: URL) async -> GitSync?
    func pullRequestNumber(for folder: URL, branch: String) async -> Int?
    func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary?
    func ciChecks(for folder: URL, branch: String) async -> ChecksSummary?
    func workingTreeFingerprint(for folder: URL) async -> String?
}

extension GitInfoProviding {
    func ciChecks(for folder: URL, branch: String) async -> ChecksSummary? { nil }
    func workingTreeFingerprint(for folder: URL) async -> String? { nil }
}

struct GitInfoService: GitInfoProviding {
    private let runner: CommandRunning
    private let gitPath: String
    private let ghPath: String?

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        gitPath: String = "/usr/bin/git",
        ghCandidates: [String] = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    ) {
        self.runner = runner
        self.gitPath = gitPath
        self.ghPath = ghCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func gitSync(for folder: URL) async -> GitSync? {
        let isRepo = git(folder, ["rev-parse", "--is-inside-work-tree"])
        guard isRepo.status == 0,
              isRepo.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }
        _ = git(folder, ["fetch", "--quiet"]) // best-effort

        let branch = git(folder, ["rev-parse", "--abbrev-ref", "HEAD"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        var behind = 0, ahead = 0, hasUpstream = false
        var upstreamRef: String?
        let revList = git(folder, ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])
        if revList.status == 0, let parsed = GitParsing.aheadBehind(fromRevListOutput: revList.stdout) {
            behind = parsed.behind; ahead = parsed.ahead; hasUpstream = true
            let upstream = git(folder, ["rev-parse", "--abbrev-ref", "@{upstream}"])
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            upstreamRef = upstream.isEmpty ? nil : upstream
        }

        var baseBehind = 0, baseAhead = 0, hasBase = false
        var baseRef: String?
        let symbolicRef = git(folder, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        if symbolicRef.status == 0, let base = GitParsing.defaultBranch(fromSymbolicRef: symbolicRef.stdout) {
            let baseRevList = git(folder, ["rev-list", "--left-right", "--count", "origin/\(base)...HEAD"])
            if baseRevList.status == 0, let parsed = GitParsing.aheadBehind(fromRevListOutput: baseRevList.stdout) {
                baseBehind = parsed.behind; baseAhead = parsed.ahead; hasBase = true
                baseRef = "origin/\(base)"
            }
        }

        let remote = git(folder, ["remote", "get-url", "origin"])
        let ownerRepo = remote.status == 0 ? GitParsing.ownerRepo(fromRemoteURL: remote.stdout) : nil

        return GitSync(
            branch: branch, behind: behind, ahead: ahead, hasUpstream: hasUpstream,
            upstreamRef: upstreamRef, baseAhead: baseAhead, baseBehind: baseBehind,
            hasBase: hasBase, baseRef: baseRef,
            owner: ownerRepo?.0, repo: ownerRepo?.1,
            issueNumber: GitParsing.issueNumber(fromBranch: branch)
        )
    }

    func pullRequestNumber(for folder: URL, branch: String) async -> Int? {
        guard let ghPath, !branch.isEmpty else { return nil }
        let result = runner.run(
            ghPath,
            ["pr", "list", "--head", branch, "--json", "number", "--jq", ".[0].number"],
            workingDirectory: folder
        )
        guard result.status == 0 else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? {
        guard let ghPath else { return nil }
        let result = runner.run(
            ghPath, ["pr", "checks", "\(prNumber)", "--json", "bucket"], workingDirectory: folder
        )
        return GitParsing.checksSummary(fromBucketJSON: result.stdout)
    }

    /// Checks for a branch head that has no pull request: the checks GitHub ran
    /// on the pushed commit. `gh pr checks` is PR scoped, so this sources the
    /// same `ChecksSummary` from the commit head instead, merging its two check
    /// systems the way the commit's status-details page does: check-runs (GitHub
    /// Actions and GitHub-App integrations) and the legacy combined commit status
    /// (status-based CI such as CircleCI). The two are distinct contexts, so the
    /// summaries simply add; the line stays hidden only when both are empty.
    ///
    /// `gh` fills the `{owner}`/`{repo}` placeholders from the folder's remote,
    /// and the branch name is the ref (GitHub resolves it to the remote head, so
    /// the line reflects the push; an unpushed branch 4xxs and yields nil).
    /// `per_page=100` keeps the check-runs response a single JSON object (rather
    /// than the invalid concatenation `--paginate` produces for object
    /// endpoints); a branch with more than 100 checks would see only the first
    /// page, which no real branch reaches.
    func ciChecks(for folder: URL, branch: String) async -> ChecksSummary? {
        guard let ghPath, !branch.isEmpty else { return nil }
        func fetch(_ path: String, _ parse: (String) -> ChecksSummary?) -> ChecksSummary? {
            let result = runner.run(ghPath, ["api", path], workingDirectory: folder)
            return result.status == 0 ? parse(result.stdout) : nil
        }
        let runs = fetch("repos/{owner}/{repo}/commits/\(branch)/check-runs?per_page=100",
                         GitParsing.checksSummary(fromCheckRunsJSON:))
        let statuses = fetch("repos/{owner}/{repo}/commits/\(branch)/status?per_page=100",
                             GitParsing.checksSummary(fromCombinedStatusJSON:))
        switch (runs, statuses) {
        case (nil, nil): return nil
        case let (runs?, nil): return runs
        case let (nil, statuses?): return statuses
        case let (runs?, statuses?): return runs.adding(statuses)
        }
    }

    /// A hash of the working tree's dirty state: `git status --porcelain` (which
    /// files are added/modified/removed/untracked) plus `git diff HEAD` (the
    /// content of tracked changes). Local only (no fetch). Respects `.gitignore`
    /// for free, since git excludes ignored paths from both commands. Returns nil
    /// when the folder is not a git work tree.
    ///
    /// Known limitation: repeated edits to the *contents* of an untracked file do
    /// not change the fingerprint, because such a file appears only as `?? path`
    /// in `git status` regardless of its contents and is absent from `git diff
    /// HEAD`. Adding/removing untracked files is detected; editing one is not.
    func workingTreeFingerprint(for folder: URL) async -> String? {
        let isRepo = git(folder, ["rev-parse", "--is-inside-work-tree"])
        guard isRepo.status == 0,
              isRepo.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }
        let status = git(folder, ["status", "--porcelain"]).stdout
        let diff = git(folder, ["diff", "HEAD"]).stdout
        let digest = SHA256.hash(data: Data((status + "\u{1F}" + diff).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func git(_ folder: URL, _ arguments: [String]) -> CommandResult {
        runner.run(gitPath, ["-C", folder.path] + arguments, workingDirectory: nil)
    }
}
