# ProcessRowView

ASCII reference layout for `ProcessRowView`, a single row inside a workspace
card's Processes group, kept in sync with the SwiftUI view so the intended
structure stays readable without running the app.

## Row

A row is a status dot plus the process name. When the process is `.orphaned`
(still running but removed from `wietty.json`) an `(orphan)` tag is
appended. A plain left click is a no-op; hovering lightens the row background
and reveals action buttons on the trailing edge. Right-clicking opens a context
menu with Start, Stop, Restart, Kill, and Open log.

```
● queue                        [◼] [⟳] [▤]    running (hovered)
○ phpunit                                      finished (exit 0)
○ npm                          [▶]  [▤]        failed (exit 1, hovered)
● migrate            (orphan)  [◼] [⟳] [▤]    orphaned, still running
```

Legend:

- `●` / `○`: status dot from `processDot(for: process.state)` — filled
  (`circle.fill`) when the process is live, open (`circle`) when it is not.
  Color follows the dot's outcome: green for success/healthy (`.running`,
  `.orphaned`, `.stopping`, `.finished`), red for `.failed`, gray/secondary for
  neutral (`.idle`, `.starting`).
- Process name: `process.name`, single line, middle-truncated.
- `(orphan)`: shown only when `process.state == .orphaned`.
- Click: no-op. Opening the log is `[▤]` and the context menu, and nothing else,
  so a click cannot take the pane from a terminal by accident.
- Selected (`isSelected`): the row whose log the pane is showing, filled the same
  way a terminal row is. The fill and the precedence over hover are
  `SidebarRowBackground`'s, so a marked process row and a marked terminal row
  cannot look like different things. See `ContentView.md`.
- Hover: the background lightens and A tooltip (`.help`) shows a human-readable
  state description (e.g. "Running", "Failed (exit 1)", "Running, but removed
  from wietty.json").
- Action buttons (visible on hover only), driven by `processIsRunning(for:)`
  which is true for `.running`/`.starting`/`.stopping`/`.orphaned`:
  - `[▶]` play (`play.fill`) → `onStart`, shown when not running.
  - `[◼]` stop (`stop.fill`) → `onStop`, shown when running.
  - `[⟳]` refresh (`arrow.clockwise`) → `onRestart`, shown when running.
  - `[▤]` log (`doc.plaintext`) → `onOpenLog`, always shown.
- Context menu: Start / Stop / Restart / Kill / Open log, wired to
  `ManagedProcess.start()/stop()/restart()/kill()` and `onOpenLog`.
