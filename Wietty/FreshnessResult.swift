import Foundation

/// The outcome of running one workspace freshness check (`CheckConfig`). Produced
/// by `FreshnessService` and stored per workspace in `ProjectStore.freshness`, it
/// is what the card's `!` marker and its detail popover read.
///
/// `actionNeeded` is the whole point: a check whose command exited non-zero is
/// asking the user to do something. `message` is the instruction to show (the
/// check's `CheckConfig.message`, or its name when that is empty), and `detail`
/// carries the command's own output so the popover can show, say, "3 commits
/// behind origin" when the check chose to print it.
struct FreshnessResult: Equatable, Sendable, Identifiable {
    /// The check's key in the `checks` map, stable and unique per workspace, so it
    /// doubles as the row identity in the detail list.
    var name: String
    var actionNeeded: Bool
    /// What the user should do, already resolved: the check's `message`, or its
    /// `name` when the message is empty. Never blank.
    var message: String
    /// The command's trimmed output, shown as secondary text under the message.
    /// Empty when the command printed nothing.
    var detail: String

    var id: String { name }

    init(name: String, actionNeeded: Bool, message: String, detail: String = "") {
        self.name = name
        self.actionNeeded = actionNeeded
        self.message = message
        self.detail = detail
    }
}

extension Array where Element == FreshnessResult {
    /// Whether the workspace should show the `!` marker: any check is asking for
    /// action. The marker is a positive signal, so a workspace with no checks, or
    /// with every check clean, shows nothing.
    var needsAttention: Bool { contains { $0.actionNeeded } }

    /// Only the checks asking for action, in the order they were run, which is what
    /// the detail popover lists.
    var actionable: [FreshnessResult] { filter { $0.actionNeeded } }
}
