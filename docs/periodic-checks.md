# Periodic Checks and Scheduling

The Wietty app continuously monitors each workspace through a tiered scheduler that runs five independent checks at different intervals depending on the workspace's state, plus one app-wide poll described separately below.

## The Workspace Checks

Wietty performs these five checks per workspace, each refreshing a different aspect of workspace information:

**Git Sync** (local)
Runs `git fetch` and computes the branch's ahead/behind status relative to its upstream. Also extracts branch metadata including any linked issue number. In addition to its scheduled runs, Git Sync is poked immediately by the `.git` watcher (see "Real-Time Git Watcher" below) so local commits and checkouts show up without waiting for the next tick.

**Pull Request Lookup** (network)
Queries GitHub for a pull request matching the current branch. Requires a non-empty branch from Git Sync to proceed. Owner and repo (also from Git Sync) are used to construct the PR URL.

**CI Checks** (network)
Fetches the CI status of the workspace's pull request from GitHub. Buckets checks into passing, failing, cancelled, skipped, and pending (in-progress checks count as pending). Requires the pull request lookup to have found a PR.

**Process Status** (local)
Re-probes daemon-kind processes that declare a status command by running that command to learn whether the backing service is up or down. Local operation, same tiering as the other checks.

**Working Tree** (local)
Computes a fingerprint of the workspace's working tree and forwards it to `TestSupervisor`, which stales any test whose last passing run was baselined against a different fingerprint. Local operation, but its tier does not follow the Decision Matrix below: like the app-wide job name poll, it runs Fast whenever its workspace is expanded and Slow when collapsed, and is not sped up further by the CI-pending or needs-attention overlays (`CheckTier.swift`, `checkTier(for:collapsed:ciPending:needsAttention:)`).

## The App-Wide Job Name Poll

One further check does not belong to a workspace. libghostty reports a terminal's title and its bell through the action callback but says nothing about its foreground command, so the only way to learn that an agent started or exited is to ask. The poll is therefore scheduled once per tick for the whole app rather than once per workspace (`JobPoll`), and `ProjectStore` is handed it as a closure (`GhosttyStack.pollJobs`).

It costs no fork: one `tcgetpgrp` on each terminal's pty master plus one `proc_name`. The same tick also refreshes the screen a remote viewer's first paint is built from, which is why the poll runs even with no workspace expanded (see `documentation/terminal.md`).

Its tier ignores the CI-pending and needs-attention overlays, because a single workspace's state must not speed up or slow down a poll that serves all of them. It runs Fast while any workspace is expanded (an agent's status is on screen) and Slow when every workspace is collapsed. Both Instant triggers reset it, so expanding a card or pressing refresh updates agent status straight away.

## Tiers and Intervals

The scheduler uses four run modes:

**Fast** (15 seconds, default)
Used when a workspace needs urgent monitoring. Shortest interval.

**Normal** (60 seconds, default)
The baseline interval for expanded (visible) workspaces at rest.

**Slow** (300 seconds, default)
Used for collapsed (hidden) workspaces where changes are less urgent to detect.

**Instant** (immediate, event-driven)
Not a repeating interval. Triggered by specific user actions:
  * Un-collapsing a workspace runs all five of its checks immediately, then returns to the normal schedule. The app-wide job name poll is reset alongside them.
  * The manual refresh button (top-right) runs all checks across all workspaces immediately, including the app-wide job name poll.

Note: Collapsing a workspace does not trigger Instant checks.

## Configurable Intervals

The three repeating intervals (Fast, Normal, Slow) are configurable in the Settings window. Only these three durations are user-editable; Instant remains event-driven and not a separate duration. Settings edits take effect on the next scheduler tick.

The valid ranges are:
  * Fast: 5 to 600 seconds
  * Normal: 10 to 3600 seconds
  * Slow: 30 to 86400 seconds

Intervals are clamped to these ranges and persisted automatically.

## The Decision Matrix

The scheduler decides each check's tier by examining the workspace's current state. The tier determines how soon the check runs next.

**Base Tier**

When the workspace is collapsed, Git Sync, Pull Request, CI Checks, and Process Status default to Slow (300s). When expanded, they default to Normal (60s).

**Tier Bumps**

Two overlays can bump a check one tier faster (from Slow to Normal, or from Normal to Fast). These bumps are cumulative and capped at Fast (the fastest interval).

  * CI-pending: When the pull request has pending or running CI checks, the CI Checks check bumps one tier faster. Does not affect other checks.
  * Needs-attention: When a terminal session in the workspace has sent a bell signal, Git Sync, Pull Request, CI Checks, and Process Status all bump one tier faster. Working Tree and the app-wide job name poll are not part of this overlay; they use the simpler two-tier rule described above.

**Matrix Table**

The table below applies to Git Sync, Pull Request, CI Checks, and Process Status. Working Tree and the job name poll are not shown; see their own sections above.

| Workspace State | Git Sync | Pull Request | CI Checks | Process Status |
|---|---|---|---|---|
| Collapsed, no needs-attention, CI settled | Slow | Slow | Slow | Slow |
| Collapsed, needs-attention, CI settled | Normal | Normal | Normal | Normal |
| Collapsed, no needs-attention, CI-pending | Slow | Slow | Normal | Slow |
| Collapsed, needs-attention, CI-pending | Normal | Normal | Fast | Normal |
| Expanded, no needs-attention, CI settled | Normal | Normal | Normal | Normal |
| Expanded, needs-attention, CI settled | Fast | Fast | Fast | Fast |
| Expanded, no needs-attention, CI-pending | Normal | Normal | Fast | Normal |
| Expanded, needs-attention, CI-pending | Fast | Fast | Fast | Fast |

## Instant Triggers

Un-collapsing a workspace or pressing the manual refresh button causes all affected checks to run immediately:

  * **Un-collapse:** When you expand a collapsed workspace, all five of its checks are marked as due and execute at once, together with the app-wide job name poll. This is useful for quickly verifying the current state after the workspace was hidden.
  * **Manual Refresh:** The refresh button (↻) at the top right of the window resets all checks in all workspaces as due, plus the app-wide job name poll, then executes them. This is a full sync across the entire project.

## Dynamic Tier Recomputation

The scheduler evaluates each check's tier on every tick (every Fast interval, 15 seconds by default). This means the decision matrix is recomputed live from the current state. If CI checks settle (all pass or complete), the CI Checks tier drops back to Normal or Slow on the next tick. Similarly, if needs-attention is cleared, the tier drops back to baseline. This ensures the scheduler naturally reflects reality: slow builds do not stay on Fast forever once they complete.

## Fixed Matrix

The tier decision matrix is built into the application code and cannot be customized by users. The rules live in `CheckTier.swift` in the `checkTier(for:collapsed:ciPending:needsAttention:)` function. Changing the matrix requires a code change and rebuild.

## Real-Time Git Watcher

Polling alone means a local commit or branch switch is only reflected on the next due Git Sync, up to one Fast interval late. To make local git actions feel immediate, the app also runs a lightweight file-system watcher over each workspace's `.git` (`GitDirWatcher`), built on the same `DispatchSource` pattern as the config-file watcher.

This is a hybrid design: the watcher does not replace polling and does not parse git state itself. It is purely a "re-read now" signal. On any observed change it marks that workspace's Git Sync check as due and runs due checks immediately, so the branch and ahead/behind counts refresh in near real time. The poll stays in place because it is the only way to see changes that are not local disk events (for example a teammate's push, which appears only after the next `git fetch`).

**What it watches.** Two stable paths, each armed with its own source:

  * `.git/logs/HEAD` (the reflog) is appended in place on every HEAD movement (commit, checkout, reset, merge, rebase), which makes it a reliable, non-replaced signal for the two most common local actions.
  * `.git/refs/heads` (a directory) changes on branch create/delete and on the ref update a commit performs.

**Scope and behavior.**

  * Only Git Sync is poked. Pull Request and CI Checks stay on their poll cadence, so a burst of local commits never triggers GitHub network lookups.
  * A single git action can touch several watched paths at once, so events are coalesced (debounced ~300ms) into a single re-read.
  * The watcher is best-effort and degrades gracefully to polling. If `.git` is absent, or is a file rather than a directory (worktrees and submodules store `.git` as a file), or a path cannot be opened, that path is skipped and the workspace simply keeps relying on the scheduled checks.
  * Remote pushes from other people, and local pushes to `origin`, are not reliably local disk events for this watcher, so they remain poll-dependent by design.

## Out of Scope

Three other real-time systems are not part of this periodic scheduler:

  * **Terminal session events:** A terminal's exit and its bell both arrive as they happen, through libghostty's action callback, and update the app immediately. The foreground job name has no signal at all behind it, which is why it is the one terminal fact that is polled (see "The App-Wide Job Name Poll" above).
  * **Config file changes:** The app watches the `wietty.json` file in each workspace folder. Changes are detected event-driven and reconciled immediately, without waiting for a scheduled check.
  * **App self-update check:** The UpdateService checks for new app versions on a separate schedule, unrelated to workspace checks.
