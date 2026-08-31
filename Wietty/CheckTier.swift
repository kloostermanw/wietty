import Foundation

/// The independently schedulable periodic checks.
enum CheckKind: CaseIterable, Hashable {
    case gitSync        // git fetch + ahead/behind (+ branch/issue metadata)
    case pullRequest    // gh pr list for the branch
    case ciChecks       // gh pr checks -> ChecksLineView
    case processStatus  // daemon status probes
    case workingTree    // local working-tree fingerprint -> test staleness
    case freshness      // per-workspace freshness checks -> the "!" marker
    case jobNames       // a terminal's foreground command -> agent status
}

/// Polling tiers, fastest first. `Instant` is not a tier; it is an event-driven
/// one-shot handled by the scheduler, not represented here.
enum CheckTier: Equatable {
    case fast, normal, slow

    /// One tier faster, clamped at `.fast`.
    func bumped() -> CheckTier {
        switch self {
        case .slow: return .normal
        case .normal: return .fast
        case .fast: return .fast
        }
    }
}

/// Decides a check's tier from live workspace context. Base tier is Slow when the
/// workspace is collapsed, Normal when expanded. Each applicable overlay bumps one
/// tier faster, cumulatively, clamped at Fast: CI-pending bumps the CI check only;
/// needs-attention bumps any check.
func checkTier(for kind: CheckKind, collapsed: Bool, ciPending: Bool, needsAttention: Bool) -> CheckTier {
    // Both are local and cheap (no network, one process), so they run fast
    // while their result is on screen and slow when it is not.
    if kind == .workingTree || kind == .jobNames { return collapsed ? .slow : .fast }
    var tier: CheckTier = collapsed ? .slow : .normal
    if kind == .ciChecks, ciPending { tier = tier.bumped() }
    if needsAttention { tier = tier.bumped() }
    return tier
}
