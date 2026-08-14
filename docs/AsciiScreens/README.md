# The views, and how they fit together

This folder holds one ASCII layout per view, so the intended structure of each
screen stays readable without running the app. This file is the map: which view
owns which window, what composes what, and which renderer draws a terminal.

Read this first, then the per view file for whichever screen you are changing.

## The scene tree

`WiettyApp` (`Wietty/WiettyApp.swift`) is the `@main` entry point. It declares one
scene, so "the app" is one window rather than a set of them.

```
WiettyApp  (@main App)
│
└── Window("Wietty", id: "main")               the only window there is
    ├── ContentView                            → ContentView.md
    └── .commands                              a modifier on this scene
        ├── Check for Updates…                 CommandGroup(after: .appInfo)
        └── SettingsCommand                    CommandGroup(replacing: .appSettings)
                                               "Settings…" plus ⌘,, which put
                                               SettingsView in the window's pane
                                               → SettingsView.md
```

One scene, and it is the app. Everything the user looks at (a local terminal, a
session on another Mac, a process log, the settings panel) is drawn in that
window's right half, so nothing opens a window except `openWindow(id: "main")`,
which the bell notification tap and the Settings menu item use to reopen the main
window if it was closed.

There is deliberately no `Settings` scene. Settings is one of the things the pane
shows, so a second window would be the only part of the app that opened one.

## The main window

`ContentView` is the root of the main window, and it has one shape: the sidebar
is the left column of a row of three, and the right column fills the rest with
`NavBarView` above `RightTerminalView`. Everything is inside Wietty (see
`../terminal.md`).

```
┌─ Wietty─── ───────────────────────────────────────────────┐
│ ▾ Local        (⟳) (+)  │ genotool                      ⚙ │  NavBarView
│ ▾ genotool              │─────────────────────────────────│
│   │  > Terminal 1       │ > implement the parser          │
│   │  ✦ Claude Code ◀ sel│ ⏺ Reading files…                │  RightTerminalView
│ ▸ genotool-admin        │ █                               │
└─────────────────────────┴─────────────────────────────────┘
  ContentView.sidebar       everything left over
  320 points by default,
  SidebarDivider between them
```

The sidebar's width is explicit (`SidebarWidth`, persisted by
`ProjectStore.sidebarWidth`) so that widening the window widens the terminal and
not the workspace list, and `SidebarDivider` is what drags it. `ContentView.md`
covers why an `HSplitView` could do neither.

The row marked `◀ sel` above is the terminal the pane is showing, filled #292b34
by `SidebarRowBackground` so the sidebar and the pane cannot disagree about which
one is on screen. `ContentView` derives both from one `PaneSelection`, and a
remote row can be the marked one just as a local row can (see
`TerminalRowView.md`).

There is no `SidebarView` type: the sidebar is a computed property,
`ContentView.sidebar`.

## What composes what

Inside the sidebar, one section per source (Local, then one per remote
connection), and one card per workspace.

```
ContentView.sidebar
│
├── ContentView.localSection
│   ├── SidebarSectionHeaderView            title, chevron, trailing buttons
│   └── WorkspaceCardView  (one per local workspace)   → WorkspaceCardView.md
│       ├── AheadBehindView                 ↑1 ↓0 per tracked branch
│       ├── IssuePRLineView                 (Issue #15) (PR #16)
│       ├── ChecksLineView                  "1 failing, 1 successful checks"
│       ├── TestProcessesLineView           → TestProcessesLineView.md
│       │   └── TestButton                  one per configured test
│       ├── TerminalRowView  (one per row)  → TerminalRowView.md
│       │   └── RowActionButton             the hover actions on a row
│       └── ProcessRowView   (one per row)  → ProcessRowView.md
│           └── RowActionButton             the same button type, shared
│
└── RemoteSectionView  (one per connection)
    ├── SidebarSectionHeaderView            reconnect and remove buttons
    └── WorkspaceCardView                   the same card, remote data
```

`RemoteSectionView` holds its `RemoteWorkspaceStore` as its own
`@ObservedObject`. That is required rather than stylistic, and `ContentView.md`
explains why: the store is nested inside a controller, so a view observing only
the controller never redraws when a snapshot arrives on the socket.

`UpdateAlertModifier` is a `ViewModifier` rather than a view, attached to the
main window. See `UpdateAlertModifier.md`.

## Three renderers draw terminals

| Renderer | View | Draws |
| --- | --- | --- |
| libghostty | `LocalTerminalView` → `SurfaceContainer` | a local terminal, in the main window's pane |
| SwiftTerm | `RemoteTerminalView`, inside `RightTerminalView` | a session on another Mac, in the same pane |
| xterm.js | `remote_index.html`, not a SwiftUI view | the browser client this app serves |

`RightTerminalView` is the one place a libghostty surface, a SwiftTerm view, a
plain text log, the settings form and a workspace's own page can appear, because
the pane holds one thing. It draws none of them itself: a local selection goes to
`LocalTerminalView`, a remote one to `RemoteTerminalView`, a log to
`ProcessLogView`, settings to `SettingsView`, a workspace page to
`WorkspaceSettingsView`, and `PaneSelection` (not a view) says which. The remote branch
carries an explicit `.id`, without which switching between two remote sessions
would reuse one view and keep the first session's connection.

`SurfaceContainer` is deliberately thin. libghostty creates a surface together
with an `NSView` and cannot exist without one, so the view belongs to
`GhosttySurfaceHost` for the terminal's whole life and this container only moves
it in and out of the window. It creates nothing and frees nothing, which is what
lets a terminal keep running while another is on screen.
`../terminal.md` covers the rest.

## Inventory

Every view type, and where its layout is documented.

| View | File | Layout documented in |
| --- | --- | --- |
| `ContentView` | `ContentView.swift` | `ContentView.md` |
| `SidebarSectionHeaderView` | `SidebarSectionHeaderView.swift` | `ContentView.md` |
| `RemoteSectionView` | `RemoteSectionView.swift` | `ContentView.md` |
| `WorkspaceCardView` | `WorkspaceCardView.swift` | `WorkspaceCardView.md` |
| `AheadBehindView` | `AheadBehindView.swift` | `WorkspaceCardView.md` |
| `IssuePRLineView` | `IssuePRLineView.swift` | `WorkspaceCardView.md` |
| `ChecksLineView` | `ChecksLineView.swift` | `WorkspaceCardView.md` |
| `TestProcessesLineView`, `TestButton` | `TestProcessesLineView.swift` | `TestProcessesLineView.md` |
| `TerminalRowView` | `TerminalRowView.swift` | `TerminalRowView.md`. Its hover and selection fills are `SidebarRowBackground.swift`, which is not a view |
| `RowActionButton` | `RowActionButton.swift` | no file of its own. The buttons it draws are described under "Action buttons" in both `TerminalRowView.md` and `ProcessRowView.md`, which are its two callers |
| `ProcessRowView` | `ProcessRowView.swift` | `ProcessRowView.md` |
| `LocalTerminalView`, `SurfaceContainer` | `LocalTerminalView.swift` | `ContentView.md` |
| `RightTerminalView` | `RightTerminalView.swift` | `ContentView.md`, under "What the pane shows". Its selection rule is `PaneSelection.swift`, which is not a view |
| `ProcessLogView` | `ProcessLogView.swift` | `ContentView.md`, under "What the pane shows" |
| `NavBarView` | `NavBarView.swift` | `NavBarView.md`. What it says is `NavBarTitle.swift`, which is not a view |
| `SidebarDivider` | `SidebarDivider.swift` | `ContentView.md`, under "Who gets the surplus, and where the divider is". Its arithmetic is `SidebarWidth.swift`, which is not a view |
| `RemoteTerminalView` | `RemoteTerminalView.swift` | `ContentView.md`, under "What the pane shows" |
| `SettingsView`, `AgentRow`, `RemoteConnectionRow` | `SettingsView.swift` | `SettingsView.md`. Drawn in the pane, and reached through `PaneRouter.swift` and `SettingsCommand` (in `WiettyApp.swift`), neither of which is a view |
| `WorkspaceSettingsView` | `WorkspaceSettingsView.swift` | `WorkspaceSettingsView.md`. Drawn in the same pane, reached from a card's "Edit workspace…" |
| `UpdateAlertModifier` | `UpdateAlertModifier.swift` | `UpdateAlertModifier.md` |

A view whose layout is already drawn inside a parent's file is documented there
rather than duplicated into a second file that would drift. That is why several
rows above point at a parent.

## Keeping this in sync

`../../CLAUDE.md` requires the `docs/` folder to track the code it
describes, so editing a view means updating its matching file in the same
change, and adding a new view worth documenting means adding a file and a row to
the inventory above.
