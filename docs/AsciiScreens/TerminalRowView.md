# TerminalRowView

ASCII reference layout for `TerminalRowView`, a single row inside a workspace
card's terminal tree, kept in sync with the SwiftUI view so the intended
structure stays readable without running the app.

## Row

A row is a leading glyph plus a label. The glyph is `terminal` (`>`) for a
terminal session and `sparkle` (`✦`) for a Claude session. When the terminal's
program reports its status (`OSC 7501`, see `../notifications.md`) a status marker is
pushed to the trailing edge; otherwise, when the row needs attention, a `🔔` is. A plain left click still
activates the terminal (`onActivate`, applied by the parent `WorkspaceCardView`);
hovering additionally lightens the row background and reveals action buttons on
the trailing edge (after any `🔔`). The right-click context menu (also applied by
the parent) is unchanged.

The `label` this view draws is composed by the parent: it passes `ref.displayName`,
which prepends an agent's configured `prefix` to the name and, under `fixed_naming`,
holds the pinned `slot` rather than a reported title. Those are `wietty.json` agent
fields (see `docs/wietty-json.md`); this view just renders the finished string.

```
> Terminal 1                 [◼] [⟳] [🗑]   terminal, running (hovered)
✦ Claude Code                              claude, running
✦ Claude Code             (selected)       claude, the one in the pane
✦ Claude Code (Python")   🔔 [◼] [⟳] [🗑]  claude, needs attention (hovered)
✦ Claude Code                 [▶] [🗑]      claude, exited (dimmed, hovered)
✦ Claude Code                     ◌        claude, program working
✦ Claude Code                 ◌ 40%        claude, working with progress
✦ Claude Code            ✋ needs you       claude, waiting for permission
✦ Claude Code                     ✓        claude, finished, not yet seen
> Terminal 1                      ✗        terminal, a program failed
```

Legend:

- `>`: terminal glyph (`kind == .terminal`).
- `✦`: Claude glyph (`kind == .claude`).
- `🔔`: trailing attention indicator (`needsAttention`), separated by a spacer.
  Not drawn while a status marker is: a program reporting its status has said more
  than a bell can, and the two would compete for the same narrow edge.
- Status marker (`programStatus`, a `ProgramStatusIndicator` built from
  `ProjectStore.programStatusSummary(for:)`): a small spinner while the program is
  working (`◌`, or the percentage beside it when it reports progress), a glyph and
  "needs you" in orange while it is blocked on you (the glyph says for what: a hand
  for permission, a speech bubble for a question, a key for a sign in, a pause sign
  otherwise), a green `checkmark.circle.fill` once it is done and a red
  `xmark.octagon.fill` on an error. Nothing for an idle program. Hovering shows the
  program's own message. Done and error stay until the row is visited or typed
  into. Fixed at 14 points high, so a spinner appearing does not make the row
  taller. A remote row never has one: the LAN protocol does not carry program
  status.
- Glyph colour tracks the session (`isRunning`, from `ProjectStore.isSessionRunning`):
  green while the terminal or agent is actually running, dimmed (tertiary) once an
  agent has exited, and neutral (secondary) otherwise (unspawned, or before the first
  job poll). A row is green regardless of whether it is the one selected in the pane,
  so a live session stays identifiable at a glance.
- Exited Claude rows (`isExited`) also render with secondary label text; there is no
  separate marker glyph, only the reduced emphasis.
- Click: activates the terminal (`onActivate`), unchanged from before.
- Hover: the background lightens (rounded `.secondary.opacity(0.12)` fill) and
  the trailing action buttons appear. Which buttons is gated on `isRunning`, the
  same positive signal the glyph colour uses (`ProjectStore.isSessionRunning`), so
  a stopped row shows play rather than a dead stop button. This is deliberately not
  `!isExited`, which is false for every plain terminal.
- Selected (`isSelected`): the row whose terminal the pane is showing, filled
  #292b34 in dark appearance and with the system's unemphasized row selection in
  light. Exactly one row in the window is ever marked, because the pane holds one
  terminal. Both the selected fill and the label colour can be overridden: Settings ›
  General › Colors carries "Active terminal row background" and "foreground", read here
  through `EnvironmentValues.sidebarColors`. When the background is set it replaces the
  #292b34 (`SidebarRowBackground.fill(activeRowBackground:)`); when the foreground is
  set the label uses it while selected. Both keep their defaults until set.

Selection and hover are both backgrounds and can both apply at once, so which
one wins is decided by `SidebarRowBackground` (`Wietty/SidebarRowBackground.swift`,
not a view) rather than inside this view. Selection wins: the pointer rests on
the selected row for most of the time anyone is looking at it, and a row that
gave up its colour to hover would be marked least often exactly when it matters.
Hovering a selected row is still visible, because the action buttons appear
either way. Both fills share one corner radius, so the shape under the pointer
does not change.
- Action buttons (visible on hover only):
  - `[◼]` stop (`stop.fill`) → `onStop`, shown when `isRunning` and `canStop` is true.
    Stops the running session but leaves the row in place so it can be reopened,
    distinct from the trash button. Absent on a remote row (`canStop` false).
  - `[⟳]` restart (`arrow.clockwise`) → `onRestart` (restart session), shown when
    `isRunning`.
  - `[▶]` play (`play.fill`) → `onPlay` (activate / relaunch), shown instead of stop
    and restart whenever the row is not running (stopped, exited, or not yet spawned).
  - `[🗑]` trash (`trash`) → `onClose` (close terminal), always shown. Removes the
    row and its terminal, so this is the delete action, kept separate from stop.
