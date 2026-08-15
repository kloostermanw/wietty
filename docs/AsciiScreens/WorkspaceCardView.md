# WorkspaceCardView

ASCII reference layout for `WorkspaceCardView`, kept in sync with the SwiftUI view
so the intended structure stays readable without running the app.

## Expanded card

A project renders as a `WorkspaceCardView`. The header carries the collapse
chevron, the project name, and the git ahead/behind indicators. Below the header
sit the Issue/PR pills, the CI checks line, the test buttons line, the
Processes group, and the terminal tree.

The ahead/behind indicators are two stacked, right aligned rows. Each row is
labeled with the remote ref it compares against: the base row against the remote
default branch (`origin/develop`), the upstream row against the branch upstream
(`origin/feature/issue-15`).

```
┌───────────────────────────────────────────────────────────────────┐
│ ▾ laravel-test                  ⟳   origin/develop            ↑1 ↓0 │
│                                      origin/feature/issue-15   ↑1 ↓0 │
│   (Issue #15)  (PR #16)                                             │
│   1 failing, 1 successfull checks                                   │
│   [phpunit] [feature-tests]                    [All]  (border=pass) │
│   │  ● queue          (filled green = running)                      │
│   │  ○ phpunit        (open green = passed)                         │
│   │  ○ npm            (open red = crashed)                          │
│   │  > Terminal 1                                                   │
│   │  ✦ Claude Code (Python")                                        │
│   │  ✦ old-agent                                     (local)        │
└───────────────────────────────────────────────────────────────────┘
```

Legend:

- `▾` / `▸`: expanded / collapsed chevron (`WorkspaceCardView.header`). The
  chevron sits in a fixed width slot and the header aligns on the first text
  baseline, so the project name keeps the same position whether the card is
  collapsed or expanded and whether the ahead/behind block has one row or two.
- `origin/... ↑a ↓b`: `AheadBehindView`, one row per comparison, label plus the
  up (ahead) and down (behind) counts.
- `(Issue #N)` / `(PR #N)`: filled pills from `IssuePRLineView`. When no issue is
  linked to the branch, the issue pill is replaced by the branch name rendered as
  plain, secondary text (no pill), so the line always shows some branch context.
- `1 failing, 1 successfull checks`: `ChecksLineView`, wording from
  `ChecksSummary.summaryText`. The line color follows `ChecksSummary.status`:
  red on failures, yellow while checks are still pending (nothing failed yet),
  green when everything completed without failures.
- `[phpunit] [feature-tests] ... [All]`: `TestProcessesLineView`, the test
  buttons flowing and wrapping on the left with an `All` button pinned to the
  top right. Rendered only when the workspace defines at least one test
  (`!tests.isEmpty`); each button's border reflects the last outcome (green
  passed, red failed, neutral for never-run/stale) with a spinner while running.
  Clicking a test button runs that test (`onTestRun`); `All` runs every test
  (`onTestRunAll`) and never shows a spinner itself; a button's context menu
  offers Run, Cancel (while running), and Open log (`onOpenTestLog`, opens a
  the pane with a `ProcessLogRef` carrying `isTest: true`). See `TestProcessesLineView.md`.
- `│`: the leading rule that groups the process and terminal rows
  (`WorkspaceCardView.children`).
- `●` / `○`: process status dot (`ProcessRowView`). Filled = running, open =
  not running; green = success/healthy, red = failed, gray = neutral.
- `>`: terminal row glyph. `✦`: Claude row glyph (`TerminalRowView`).
- Hovering a row reveals trailing action buttons (play / stop / refresh, plus a
  log button on process rows). A plain click on a process row is a no-op, while a
  plain click on a terminal or Claude row activates it (`onActivate`), which shows
  it in the terminal pane beside the sidebar. `ContentView.activate` returns after
  the store call, because selecting the session is what puts its surface in the
  pane and nothing else has to happen.

  A click on a row whose terminal has stopped reopens it. The service answers that
  itself, because its record of a dead terminal survives so the last screen stays
  readable; see `docs/terminal.md`.
  Terminal buttons are wired here to `onActivate` (play), `onCloseTerminal`
  (stop), and `onRestartTerminal` (refresh). See `ProcessRowView.md` and
  `TerminalRowView.md`.
- A terminal or Claude row's context menu offers "Rename" (terminal rows only),
  "Remove", and "Close terminal".
- "Remove" and "Close terminal" both close the terminal in the end: the row is the
  only handle there is, so dropping it closes the terminal too rather than leaving
  a shell running that nothing can reach (`ProjectStore.releaseOrphaned`).
- `⟳`: appears only when `wietty.json` changed on disk. Clicking it applies
  the file to the rows (`WorkspaceCardView.header`, `onApplyConfig`).
- `(local)`: a row tracked locally but absent from `wietty.json`, kept alive
  after an external removal (`TerminalRowView`, `isLocalOnly`).

## The workspace header's context menu

Right clicking the header opens this. The items come from `WorkspaceMenu.items`,
a pure type, so which of them a card offers and in what order is asserted in CI
(`WorkspaceMenuTests`) rather than only checkable by right clicking one. The card
supplies the actions, which is the half that needs a card.

```
┌────────────────────────┐
│ Add Terminal           │┌────────────────────────────┐
│ Add Agent            > ││ Claude                     │
│ Add Agent with args  > ││ Codex                      │
│ Add workspace...       │└────────────────────────────┘
│ ────────────────────── │  one entry per configured agent,
│ Edit workspace...      │  from Settings › Agents
│ Rename workspace...    │
│ Enable config sync     │  (only while sync is off)
│ Remove                 │
└────────────────────────┘
```

- Everything above the separator adds something; everything below it acts on the
  workspace itself. "Remove" sitting among the "add" entries is how a click meant
  for one lands on the other.
- "Add Terminal" (`onOpenTerminal`) opens a plain terminal row.
- "Add Agent" (`onAddAgent`) starts one of the agents configured in Settings ›
  Agents, with that agent's default arguments. "Add Agent with args"
  (`onAddAgentWithArgs`) is the same list, and asks what to run it with first; the
  dialog is described under "Overlays and alerts" in `ContentView.md`. Both
  submenus are the same list (`agents`), so an agent added in Settings appears
  under both. With no agents configured, each submenu holds one disabled line
  pointing at Settings (`WorkspaceMenu.noAgents`), because a submenu with nothing
  in it reads as a menu that failed to build.
- "Add workspace…" (`onAddWorkspace`) is the `+` in the Local header, offered here
  too because a right click on a card is where a user already is when they want one
  more.
- "Edit workspace…" (`onEditWorkspace`) puts this workspace's own page in the pane,
  the way the gear puts the app's settings there. See `WorkspaceSettingsView.md`.
- "Rename workspace…" (`onRenameWorkspace`) opens the rename dialog, described
  under "Overlays and alerts" in `ContentView.md`.
- "Enable config sync" (`onEnableSync`) appears only while sync is off, since sync
  can only be turned on.
- "Remove" (`onRemoveProject`) drops the workspace and its rows the way the row
  menu's "Remove" drops one, so it closes their terminals too.

A remote card offers two items and no separator: "Add Terminal" and "Claude"
(`onOpenClaude`). Those are what the LAN remote protocol carries. The agent list is
this Mac's preference and means nothing on the Mac serving that workspace, and the
workspace itself is not this app's to edit, rename or remove: "Edit workspace…" and
"Rename workspace…" are absent whenever their actions are nil, which is every
remote card.

The change indicator and the enable action only appear for workspaces that have,
or can have, a `wietty.json`. "Enable config sync" lives in the header's
context menu, shown only while sync is off, and writes the file from the
workspace's current rows.

## Collapsed card

When collapsed, the chevron flips and everything below and beside the header is
hidden: the terminal tree, the Processes group, the Issue/PR pills, the checks
line, and the ahead/behind indicators. Only the chevron and project name
remain.

```
┌───────────────────────────────────────────────────────────────────┐
│ ▸ laravel-test                                                      │
└───────────────────────────────────────────────────────────────────┘
```
