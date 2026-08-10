# NavBarView

ASCII reference layout for `NavBarView`, the bar across the top of the window's
right half, kept in sync with the SwiftUI view so the intended structure stays
readable without running the app.

## Where it sits

In the right column only. The window is a row of three (sidebar, `SidebarDivider`,
right column), and the bar is the first row of that third part, with a `Divider`
between it and the pane. Nothing of it is above the sidebar, which keeps the full
height of the window.

```
┌─ Wietty─── ───────────────────────────────────────────────┐
│ ▾ Local        (⟳) (+)  │ Office Mac / web-app            │  NavBarView, 28 points
│ ▾ genotool              │─────────────────────────────────│  Divider
│   │  > Terminal 1       │ > implement the parser          │
│   │  ✦ Claude Code      │ ⏺ Reading files…                │  RightTerminalView
│ ▸ genotool-admin        │ █                               │
└─────────────────────────┴─────────────────────────────────┘
```

It is always present, including when nothing is selected, in which case it is
empty. A bar that appeared and disappeared would move the whole pane height with
it, so the terminal underneath would jump every time a selection was cleared.

Its height is `NavBarView.height` (28 points) and it is part of the window's
minimum: `SidebarWidth.windowMinimumHeight` is the pane's own floor plus the bar
plus the divider. Leaving it out would squeeze the pane exactly one bar below its
minimum, which is the same arithmetic mistake `SidebarWidth.dividerWidth` exists to
prevent horizontally.

## What it says

The workspace whatever the pane is showing belongs to, and nothing else yet.

| Pane content | Bar |
| --- | --- |
| A local terminal | the workspace holding that row, `genotool` |
| A process log | that log's own workspace, `genotool` |
| A session on another Mac | the connection first, `Office Mac / web-app` |
| Nothing selected | empty |

The connection comes first for a remote session because two Macs routinely have a
workspace with the same name, so `web-app` alone would not say which one. That is
also how the sidebar reads: the section header is the connection, the card under it
is the workspace.

## How that is decided

Two pure steps in `NavBarTitle`, both tested without SwiftUI in
`NavBarTitleTests`, because they can be wrong in different ways:

- `NavBarTitle.origin(for:projects:remote:)` finds the workspace, returning a
  `PaneOrigin` (a workspace name, and a connection name for anything on another
  Mac). A local terminal is found by the row carrying its session id, a log by its
  `projectId`, and a remote session through the `remote` closure, which is a
  closure because that answer lives in a live snapshot this function has no
  business knowing about.
- `NavBarTitle.text(for:)` turns that into the line, which is where the
  `connection / workspace` shape lives.

Nil is a real answer at every branch and never a crash: a session id can outlive
the row that carried it, a workspace can be removed while its log is on screen, and
a connection may not have delivered a snapshot yet. The bar is empty in all three
cases, which is better than a stale name.

The view supplies the remote lookup itself, walking
`RemoteWorkspacesController.stores[connectionId]` for the workspace whose sessions
contain that session id. The controller is an `@ObservedObject` rather than read
once, because a remote workspace's name arrives in a snapshot and can change while
its session is on screen.
