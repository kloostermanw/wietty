import Foundation

struct ChecksSummary: Equatable, Sendable {
    var passing: Int
    var failing: Int
    var cancelled: Int
    var skipped: Int
    var pending: Int

    var total: Int { passing + failing + cancelled + skipped + pending }
    var hasFailures: Bool { failing + cancelled > 0 }

    /// Overall state of the checks. Failures always win over pending, which
    /// wins over success.
    var status: ChecksStatus {
        if hasFailures { return .failed }
        if pending > 0 { return .running }
        return .passed
    }

    var summaryText: String {
        var parts: [String] = []
        if failing > 0 { parts.append("\(failing) failing") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if passing > 0 { parts.append("\(passing) successfull checks") }
        if pending > 0 { parts.append("\(pending) pending") }
        return parts.joined(separator: ", ")
    }
}

/// Three-way outcome of a `ChecksSummary`, used to color `ChecksLineView`.
enum ChecksStatus: Equatable, Sendable {
    case failed
    case running
    case passed
}

/// The slice of workspace info produced by the git sync check (no network calls
/// to GitHub; only `git`).
struct GitSync: Equatable, Sendable {
    var branch: String
    var behind: Int
    var ahead: Int
    var hasUpstream: Bool
    var upstreamRef: String?
    var baseAhead: Int
    var baseBehind: Int
    var hasBase: Bool
    var baseRef: String?
    var owner: String?
    var repo: String?
    var issueNumber: Int?
}

struct GitInfo: Equatable, Sendable {
    var branch: String
    var behind: Int
    var ahead: Int
    var hasUpstream: Bool
    var upstreamRef: String? = nil
    var baseAhead: Int = 0
    var baseBehind: Int = 0
    var hasBase: Bool = false
    var baseRef: String? = nil
    var issueNumber: Int?
    var prNumber: Int?
    var issueURL: URL?
    var prURL: URL?
    var checks: ChecksSummary?
}
