import Foundation

package struct ChecksSummary: Equatable, Sendable {
    package var passing: Int
    package var failing: Int
    package var cancelled: Int
    package var skipped: Int
    package var pending: Int

    /// Spelled out for the reason `GitInfo`'s is: the remote adapter builds one in
    /// the app from what another Mac reported.
    package init(passing: Int, failing: Int, cancelled: Int, skipped: Int, pending: Int) {
        self.passing = passing
        self.failing = failing
        self.cancelled = cancelled
        self.skipped = skipped
        self.pending = pending
    }

    package var total: Int { passing + failing + cancelled + skipped + pending }
    package var hasFailures: Bool { failing + cancelled > 0 }

    /// Overall state of the checks. Failures always win over pending, which
    /// wins over success.
    package var status: ChecksStatus {
        if hasFailures { return .failed }
        if pending > 0 { return .running }
        return .passed
    }

    package var summaryText: String {
        var parts: [String] = []
        if failing > 0 { parts.append("\(failing) failing") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if passing > 0 { parts.append("\(passing) successfull checks") }
        if pending > 0 { parts.append("\(pending) pending") }
        return parts.joined(separator: ", ")
    }
}

/// Three-way outcome of a `ChecksSummary`, used to color `ChecksLineView`.
package enum ChecksStatus: Equatable, Sendable {
    case failed
    case running
    case passed
}

/// The slice of workspace info produced by the git sync check (no network calls
/// to GitHub; only `git`).
package struct GitSync: Equatable, Sendable {
    /// Spelled out because the implicit memberwise one is internal and its
    /// callers are in the other module.
    package init(branch: String, behind: Int, ahead: Int, hasUpstream: Bool, upstreamRef: String?, baseAhead: Int, baseBehind: Int, hasBase: Bool, baseRef: String?, owner: String?, repo: String?, issueNumber: Int?) {
        self.branch = branch
        self.behind = behind
        self.ahead = ahead
        self.hasUpstream = hasUpstream
        self.upstreamRef = upstreamRef
        self.baseAhead = baseAhead
        self.baseBehind = baseBehind
        self.hasBase = hasBase
        self.baseRef = baseRef
        self.owner = owner
        self.repo = repo
        self.issueNumber = issueNumber
    }

    package var branch: String
    package var behind: Int
    package var ahead: Int
    package var hasUpstream: Bool
    package var upstreamRef: String?
    package var baseAhead: Int
    package var baseBehind: Int
    package var hasBase: Bool
    package var baseRef: String?
    package var owner: String?
    package var repo: String?
    package var issueNumber: Int?
}

package struct GitInfo: Equatable, Sendable {
    package var branch: String
    package var behind: Int
    package var ahead: Int
    package var hasUpstream: Bool
    package var upstreamRef: String? = nil
    package var baseAhead: Int = 0
    package var baseBehind: Int = 0
    package var hasBase: Bool = false
    package var baseRef: String? = nil
    package var issueNumber: Int?
    package var prNumber: Int?
    package var issueURL: URL?
    package var prURL: URL?
    package var checks: ChecksSummary?
    /// Uncommitted paths in the working tree, written by the `.workingTree` check.
    package var uncommitted: Int = 0

    /// Spelled out because the implicit memberwise one is internal, and
    /// `RemoteProjectAdapter` builds one in the app from what another Mac reported.
    /// Every default is repeated, because a hand written memberwise initializer does
    /// not inherit the properties' own.
    package init(branch: String, behind: Int, ahead: Int, hasUpstream: Bool,
                 upstreamRef: String? = nil, baseAhead: Int = 0, baseBehind: Int = 0,
                 hasBase: Bool = false, baseRef: String? = nil,
                 issueNumber: Int? = nil, prNumber: Int? = nil,
                 issueURL: URL? = nil, prURL: URL? = nil,
                 checks: ChecksSummary? = nil, uncommitted: Int = 0) {
        self.branch = branch
        self.behind = behind
        self.ahead = ahead
        self.hasUpstream = hasUpstream
        self.upstreamRef = upstreamRef
        self.baseAhead = baseAhead
        self.baseBehind = baseBehind
        self.hasBase = hasBase
        self.baseRef = baseRef
        self.issueNumber = issueNumber
        self.prNumber = prNumber
        self.issueURL = issueURL
        self.prURL = prURL
        self.checks = checks
        self.uncommitted = uncommitted
    }
}
