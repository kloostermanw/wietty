# WorkspaceSettingsView

ASCII reference layout for `WorkspaceSettingsView`, kept in sync with the SwiftUI
view so the intended structure stays readable without running the app.

One workspace's own page. It is reached from "Edit workspace…" in that workspace's
context menu (`WorkspaceCardView.md`) and drawn in the main window's pane, the way
the app's own settings are: a page rather than a window, so it goes where every
other page goes.

```
┌─ pane ───────────────────────────────────────────┐
│ wietty settings                              ⚙   │  NavBarView
│ ────────────────────────────────────────────────  │
│                                                    │
│                    ≡                               │
│         No workspace settings yet                  │
│    Settings for this workspace will appear         │
│    here. Its terminals, agents and processes       │
│    are on the card in the sidebar.                 │
│                                                    │
└──────────────────────────────────────────────────┘
```

Empty on purpose. The workspace things worth a page (the rows, the name, the
`wietty.json` the card already syncs) are each reachable from the card itself
today, so the page exists ahead of the settings that will move here rather than
alongside a half of them. It says so, because a page that drew nothing would read
as a page that failed to load. The strings are statics on the view
(`WorkspaceSettingsView.title`, `.message`, `.systemImage`) for the same reason
`SettingsTab` is a pure type: what a screen says is a fact about the app, and a
fact about the app belongs in CI (`WorkspacePaneTests`).

## The bar above it

`NavBarTitle.line` answers "wietty settings": the workspace's name and what the
page is, so it does not read as one of that workspace's terminals. It answers
nothing at all for a workspace that has been removed, which is the same rule every
other branch of the lookup follows: a stale name would be worse than none.

## Getting out of it

The same two ways out the settings panel has, and for the same reasons
(`ContentView.md`, "What the pane shows"): activating a terminal row puts that
terminal back, and there is no close button because of it.

One rule of its own, in `PaneRouter.workspacesChanged`: removing the workspace
takes its page off the screen. The card and its rows went with the workspace, so
the page would otherwise be a dead end with nothing in the sidebar left to click
out of it, which is exactly what a removed connection used to leave behind. Only
that page: a process log belongs to a workspace too and stays, because it is text
this app already holds and is still readable afterwards, and the app's own settings
panel belongs to no workspace at all, so removing one must not close it under the
cursor of whoever is using it.

`WorkspaceSettingsView` covers the frame between the removal and that rule firing
by drawing a "Workspace removed" placeholder when it is handed no workspace, the
way the pane's "Connection removed" placeholder does.
