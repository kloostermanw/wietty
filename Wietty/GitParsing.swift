import Foundation

enum GitParsing {
    /// The integer value of the maximal run of trailing digits in the branch
    /// name, or nil if the branch does not end in a digit.
    static func issueNumber(fromBranch branch: String) -> Int? {
        var reversedDigits = ""
        for character in branch.reversed() {
            if character.isNumber {
                reversedDigits.append(character)
            } else {
                break
            }
        }
        guard !reversedDigits.isEmpty else { return nil }
        return Int(String(reversedDigits.reversed()))
    }

    /// Parses `git rev-list --left-right --count` output ("behind<ws>ahead").
    static func aheadBehind(fromRevListOutput output: String) -> (behind: Int, ahead: Int)? {
        let parts = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            return nil
        }
        return (behind, ahead)
    }

    /// Parses a GitHub origin URL (https or ssh) into owner/repo.
    static func ownerRepo(fromRemoteURL url: String) -> (owner: String, repo: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String
        if let range = trimmed.range(of: "github.com/") {
            path = String(trimmed[range.upperBound...])
        } else if let range = trimmed.range(of: "github.com:") {
            path = String(trimmed[range.upperBound...])
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return (String(components[0]), String(components[1]))
    }

    /// Extracts the default branch name from `git symbolic-ref --short
    /// refs/remotes/origin/HEAD` output (e.g. "origin/develop" -> "develop").
    static func defaultBranch(fromSymbolicRef output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "origin/") {
            let rest = String(trimmed[range.upperBound...])
            return rest.isEmpty ? nil : rest
        }
        return trimmed
    }

    /// Tallies `gh pr checks --json bucket` output into a ChecksSummary.
    /// Returns nil when the JSON is empty, invalid, or has no check rows.
    static func checksSummary(fromBucketJSON json: String) -> ChecksSummary? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        struct Row: Decodable { let bucket: String }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        var summary = ChecksSummary(passing: 0, failing: 0, cancelled: 0, skipped: 0, pending: 0)
        for row in rows {
            switch row.bucket {
            case "pass": summary.passing += 1
            case "fail": summary.failing += 1
            case "cancel": summary.cancelled += 1
            case "skipping": summary.skipped += 1
            case "pending": summary.pending += 1
            default: break
            }
        }
        return summary.total > 0 ? summary : nil
    }

    /// Tallies a GraphQL `statusCheckRollup` response into a ChecksSummary, for a
    /// branch head that has no pull request. This is the same source GitHub's UI
    /// and `gh pr checks` use: the rollup keeps only the latest run per check
    /// suite and context, so a SHA whose head has not moved (and has collected a
    /// fresh Dependabot check suite on every scheduled run) is not over-counted
    /// the way the raw check-runs endpoint would be.
    ///
    /// Each context node is either a `CheckRun` (GitHub Actions and GitHub-App
    /// integrations, with `status`/`conclusion`) or a `StatusContext` (the legacy
    /// commit status, status-based CI such as CircleCI, with a flat `state`); the
    /// rollup already merges both, so no separate request or field-wise add is
    /// needed. The GraphQL enums are uppercase where the REST fields were
    /// lowercase. Returns nil when the response is empty, invalid, carries a
    /// top-level `errors` array (a partial-data response, whose `data` must not be
    /// counted), has a null `object` (no pushed commit), a null `statusCheckRollup`
    /// (the commit has no checks), or empty contexts.
    static func checksSummary(fromRollupJSON json: String) -> ChecksSummary? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        struct Payload: Decodable {
            struct DataField: Decodable {
                struct Repository: Decodable {
                    struct Object: Decodable {
                        struct Rollup: Decodable {
                            struct Contexts: Decodable {
                                struct Node: Decodable {
                                    let typename: String?
                                    let status: String?
                                    let conclusion: String?
                                    let state: String?
                                    enum CodingKeys: String, CodingKey {
                                        case typename = "__typename"
                                        case status, conclusion, state
                                    }
                                }
                                let nodes: [Node]
                            }
                            let contexts: Contexts
                        }
                        let statusCheckRollup: Rollup?
                    }
                    let object: Object?
                }
                let repository: Repository?
            }
            struct GraphQLError: Decodable {}
            let data: DataField?
            let errors: [GraphQLError]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.errors?.isEmpty ?? true,
              let rollup = payload.data?.repository?.object?.statusCheckRollup else { return nil }
        var summary = ChecksSummary(passing: 0, failing: 0, cancelled: 0, skipped: 0, pending: 0)
        for node in rollup.contexts.nodes {
            switch node.typename {
            case "CheckRun":
                guard node.status == "COMPLETED" else { summary.pending += 1; continue }
                switch node.conclusion {
                case "SUCCESS", "NEUTRAL": summary.passing += 1
                case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": summary.failing += 1
                case "CANCELLED": summary.cancelled += 1
                case "SKIPPED": summary.skipped += 1
                default: break
                }
            case "StatusContext":
                switch node.state {
                case "SUCCESS": summary.passing += 1
                // EXPECTED is a required status that has not reported yet, which is pending.
                case "PENDING", "EXPECTED": summary.pending += 1
                case "FAILURE", "ERROR": summary.failing += 1
                default: break
                }
            default: break
            }
        }
        return summary.total > 0 ? summary : nil
    }
}
