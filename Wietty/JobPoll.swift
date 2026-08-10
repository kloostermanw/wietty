import Foundation

/// The app-wide job name poll.
///
/// libghostty pushes a terminal's title and its bell through its action callback
/// but says nothing about its foreground command, so the only way to learn that an
/// agent started or exited is to ask. One pass covers every live terminal, which
/// makes this a single scheduled check for the whole app rather than one per
/// workspace.
///
/// It costs no fork at all: one `tcgetpgrp` per terminal plus one `proc_name`.
enum JobPoll {
    /// Fixed schedule key for the app-wide poll. Workspace ids are random UUIDs,
    /// so this reserved one cannot collide with a workspace's own keys.
    static let key = ScheduleKey(
        projectId: UUID(uuidString: "00000000-0000-0000-0000-00000000704D")!,
        kind: .jobNames)

    /// Fast while any workspace is expanded, because that is when an agent's
    /// status is on screen; slow when everything is collapsed.
    static func tier(anyExpanded: Bool) -> CheckTier {
        checkTier(for: .jobNames, collapsed: !anyExpanded, ciPending: false, needsAttention: false)
    }
}
