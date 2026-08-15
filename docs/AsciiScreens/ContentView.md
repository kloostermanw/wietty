# ContentView

ASCII reference layout for `ContentView`, the top level sidebar window, kept in
sync with the SwiftUI view so the intended structure stays readable without
running the app.

## Window

The window is a row of three: the sidebar at an explicit width, a
`SidebarDivider`, and the right column taking everything left over, because
everything the user looks at lives inside this window. That third part is itself
two rows, `NavBarView` above a `Divider` above `RightTerminalView`, so only the
divider is to the bar's left and the sidebar keeps the full height.

```
┌─ Wietty ────────────────────────────────────────────────────────────────────┐
│                    ( ⟳ )  ( + )  │ Wietty                                 ⚙ │
│                                  ├──────────────────────────────────────────┤
│ ▾ Wietty  origin/develop ↑1 ↓0   │ > implement the parser                   │
│   │  > Terminal 1                │ ⏺ Reading files…                         │
│   │  ✦ Claude Code   ◀ selected  │ █                                        │
│ ························· Divider│                                          │
│ ▸ api-service                    │                                          │
└──────────────────────────────────┴──────────────────────────────────────────┘
  sidebar, 320 points by default     NavBarView, 28 points, then
  SidebarDivider sits between them,  RightTerminalView with the rest
  six points wide and draggable
```

The bar says which workspace the pane's content belongs to, or `Settings` for the
panel, and is empty when nothing is selected. Its trailing gear toggles that panel and
is the only way into it that is inside the window, which has no title bar to hold
anything of its own. See `NavBarView.md`, which also covers why its height is part of
the window's minimum.

The Local header offers refreshing git status and adding a folder, and nothing
else. See `ContentView.localSectionButtons(refresh:add:)`. It carries no title
above, because this window has no remote connection: the word Local and its
chevron only appear once there is a remote section to tell it apart from. See
"The sidebar" below.

## What the pane shows

One thing at a time. Three of the five are kinds the sidebar lists: a local
libghostty surface, a session on another Mac over the LAN remote protocol, or a
supervised process's log. The other two are pages: the app's own settings, which
belongs to no workspace and so marks no row, and one workspace's own page, reached
from that card's "Edit workspace…". `RightTerminalView` is only the seam. A local
selection (or none at all) goes to `LocalTerminalView`, described next; a remote
one to `RemoteTerminalView`, a SwiftTerm viewer over a socket to that Mac; a log
to `ProcessLogView`, which is text this app already holds; settings to
`SettingsView` (see `SettingsView.md`); a workspace to `WorkspaceSettingsView`
(see `WorkspaceSettingsView.md`).

`PaneSelection` decides which, from two pieces of state that live apart and stay
apart: the local selection belongs to `GhosttyService`, and `PaneRouter.override`
holds whatever covers it. That override is one value (`PaneOverride`: a remote
session, a log, settings, or a workspace page) rather than four, because no two of
them can be on screen at once: held apart, every place that set one would have to
remember to clear the others, and the one that forgot would leave the sidebar
marking a row the pane is not showing.

`PaneRouter` is owned by `WiettyApp` rather than held as `ContentView` state, for
one reason: the app menu's "Settings…" item and ⌘, are declared in the scene's
`commands` (`SettingsCommand`), which cannot reach a view's `@State`. The gear in
the bar and the menu item then go through the same object. It also holds every rule
that uncovers the terminal, because a rule written inside a `.task` closure cannot be
asserted in CI, and one of them was wrong for exactly that reason (see below).
`PaneRouterTests` covers them now.

The menu item opens or focuses the main window before setting the override, the way a
tapped bell notification does, since the window can be closed while the app runs and a
panel in a pane nobody can see is not an answer. There is no `Settings` scene: settings
is one of the things this window's pane shows, so a second window would be the only
part of the app that opened one.

An override covers the local selection rather than replacing it, so nothing about
the local terminal changes while a remote session, a log, or settings is on screen,
and clearing the override puts the local terminal back. Three things clear it.

Activating a terminal row clears it directly (`ContentView.activate`). This is not
redundant with the callback below, it is the main path: because an override *covers*
the local selection, the terminal a user clicks to get back is usually the one that is
still selected, and `GhosttyService.select` returns early when the session is already
selected, so no callback arrives. Relying on the callback alone left that click dead
and left the settings panel, which has no close button, with no exit at all.

A selection the service reports clears it too, which is what makes a click on a
different row, the MCP server, or a remote client show that terminal even while
something else is on screen. That is deliberately keyed on a non-nil selection: the
service also selects nil when the last local terminal closes, and blanking a pane
someone is reading would be a bug rather than an intent. Closing one local terminal
while another remains does take the pane, because the service selects that other
terminal and nothing here can tell that apart from a click.

The gear toggles, so it is also a way out, and the only one when no local terminal is
selected: a fresh install has no row to activate.

Only the remote session on screen holds a socket. Its view carries an explicit
`.id`, so switching sessions discards the view rather than reusing it, and
`RemoteTerminalView.dismantleNSView` stops the connection. Without that id one
pane position would keep the first session's connection while claiming to show
the second, which the tabbed window never had to worry about because it keyed
every tab. Coming back attaches again and the server paints the current screen,
so what is lost is that viewer's scrollback and not the screen. A remote session
that ends while it is on screen keeps its last output under a `[session ended]`
banner, matching what this pane does for a local terminal whose command exited.

A connection removed, from the sidebar or from the settings panel, takes its
terminal off the screen and puts the local one back, because the rows went with it
and a placeholder would be a dead end with nothing left to click out of it.
`RightTerminalView`'s "Connection removed" placeholder still earns its place: it
covers the frame between the store changing and the override being cleared.

A workspace removed while its own page is on screen is the same situation and gets
the same treatment (`PaneRouter.workspacesChanged`, wired to the workspace ids
rather than the workspaces, so a rename is not a removal). Only that page: a
process log belongs to a workspace too and stays readable after it is gone, and the
settings panel belongs to no workspace at all. See `WorkspaceSettingsView.md`.

## The local terminal in the pane

The pane shows the selected terminal's surface and nothing else. Only one surface
is in the window's view hierarchy at a time; every other one stays alive and keeps
reading, which is how Ghostty's own tabs behave and is why a terminal keeps
running while another is on screen. Selecting a row moves that one view rather
than building a new one, and a surface is never rebuilt: rebuilding is what would
lose the scrollback. `ContentView` mirrors `GhosttyService.selected` into
`selectedTerminal` through `onSelectionChanged`, so a selection made by a click, by
the MCP server, or by a remote client redraws the pane the same way. A terminal
whose command has exited keeps its surface until the row is closed, so the pane
keeps showing the last screen that command printed. The pane's three states are
`GhosttyPaneState`: the terminal's setup error, the selected terminal, or a
placeholder when nothing is selected. See `LocalTerminalView`.

Dropping files from Finder onto the pane inserts their paths at the cursor, shell
quoted and space separated, the standard macOS terminal gesture for handing a file
to a running CLI. The surface itself is the drop target; see "Dropping files onto
the pane" in `docs/terminal.md`.

The same `PaneSelection` marks the row, through `WorkspaceCardView.isSelected`
for a terminal row and `isProcessSelected` for a process row: a row is marked when
it is what the pane is drawn from, so the highlighted row and the thing on screen
cannot disagree, whichever path made the selection. Exactly one row is ever
marked, because the pane holds one thing.

Each kind's match is on everything that makes it unique. A remote row matches on
the connection as well as the session id, since two Macs routinely hand out the
same id. A process row matches on the workspace as well as the name, since two
workspaces routinely declare a process under the same name, and on `isTest`, since
processes and tests are separate namespaces that may share one. No selection
matches no row, which is what leaves every row unmarked before anything has been
clicked. The fill itself is `SidebarRowBackground` and is described in
`TerminalRowView.md`.

## The process log in the pane

A log is not something a click on its row selects, the way a terminal is. Clicking
a process row still does nothing; the log arrives through `[▤]` or the context
menu's "Open log", which is what `ProcessRowView.md` describes. Once it is there it
behaves exactly like a remote session: it stays until a terminal or remote row is
clicked, and its process row is marked while it is on screen.

`ProcessLogView` looks its process up by `ProcessLogRef` on every redraw rather
than holding it, because a process can be stopped, restarted, or dropped from the
config while its log is on screen. `isTest` picks the namespace:
`store.testSupervisor.test(projectId:name:)` when true, otherwise
`store.processes.process(projectId:name:)`. A log whose process can no longer be
found shows "Process not found", which is reachable by removing the workspace or
editing the process out of `wietty.json` while its log is up.

```
┌ ▸ genotool ───────────────────────────────────────────────────────┐
│ > project@0.0.0 dev                                                │
│ > vite                                                             │
│                                                                    │
│   VITE v5.0.0  ready in 320 ms                                     │
│   ➜  Local:   http://localhost:5173/                               │
│ [new lines keep appearing here, the view auto-scrolls to the end]  │
└────────────────────────────────────────────────────────────────────┘
```

The body is a scrollable, monospaced, read-only, selectable dump of
`ManagedProcess.log.lines`, with a `ScrollViewReader` jumping to a hidden bottom
anchor whenever the line count changes.

### Who gets the surplus, and where the divider is

The split is not an `HSplitView`, and the reason is behavioural. `HSplitView`
handed a widened window to the **sidebar**, so making the window bigger made the
workspace list bigger and left the terminal pinned at its 480 point minimum, and
it offers neither a binding nor an autosave name, so the divider forgot where the
user put it on every relaunch. It is a `GeometryReader` around an `HStack` now:
the sidebar carries an explicit width, so the pane is the only flexible half and
absorbs every resize, and the width is a number the app owns and can persist.

Three pieces, each with one job. `SidebarWidth` is the arithmetic (the 240 point
sidebar floor, the 480 point pane floor, the 6 points the divider occupies, the
320 point default, and the clamp), `SidebarDivider` is the hit area, the resize
cursor and the drag, and `ProjectStore.sidebarWidth` is the persisted value, written
to `~/.config/wietty/config` under `sidebar-width` (see settings-storage.md). The
live width while a drag is running is `@State` in `ContentView`, and the store is
written once, on release, so one drag is one file write rather than one per frame.
That state starts nil and falls
back to the store, which is what makes the first frame after a launch the stored
width rather than the default.

Measured in a running window: a stored width of 320 gives halves of 320 and 774
in an 1100 point window and 320 and 1274 in a 1600 point one, so widening moves
only the pane. Dragging right stops at 914 in a 1400 point window, where the pane
is exactly 480, and dragging left stops at 240.

The pane also has to ask for the whole height of the window
(`.frame(minWidth: SidebarWidth.paneMinimum, minHeight: SidebarWidth.paneMinimumHeight, maxHeight: .infinity)`),
and that is a requirement rather than a preference. Only one thing here ever asks
for the whole height on its own: the attached surface, because `SurfaceContainer`
is an `NSViewRepresentable` and so has no ideal size. Both placeholders ask for
their content instead, and under the previous `HSplitView` that made the whole
split view 240 points tall (the pane's minimum), sitting at the bottom of the
window, since an AppKit view laid out short of its superview keeps its bottom left
origin. The sidebar cannot carry that greed instead: it sizes itself from its own
content, which is what keeps the workspace list from stretching.

The window's own minimum has to be restated on the split
(`.frame(minWidth: SidebarWidth.windowMinimumWidth, minHeight: SidebarWidth.windowMinimumHeight)`,
so 726 by 240 of content, which macOS reports as a 726 by 272 window). A
`GeometryReader` answers with whatever size it is offered and never reports what
its content needs, so unlike `HSplitView`'s arranged subviews it does not carry the
two halves' minimums up to the window. Without that line the window had no minimum
at all (measured `contentMin` of `0.0x32.0`), and at 500 points the terminal ran 226
points off the right edge while the sidebar's content was squeezed under its own
240.

The default window size is 1100 by 760 for the same reason: 300 points would be
narrower than the two halves' own minimums (240 and 480) and a window that opened
at it would be clamped to the smallest terminal the pane allows. A window the user
has already sized keeps its saved frame.

## The sidebar

The sidebar is a vertical scroll view made of one **Local** section followed
by one **Remote** section per connection in `remoteConnections.connections`
(each backed by a live `RemoteWorkspaceStore` from `remoteWorkspaces.stores`).
Each Remote section is rendered by `RemoteSectionView`, which holds its store as
its own `@ObservedObject`. That is required, not stylistic: the store is a nested
`ObservableObject` inside `RemoteWorkspacesController`, so a view observing only
the controller never redraws when a snapshot arrives on the socket.
Each section starts with a `SidebarSectionHeaderView` and, unless collapsed
(`sections: SectionCollapseState`, keyed `"local"` / `"remote-<connection id>"`,
and for the Local section resolved by `LocalSectionHeader`),
lists one `WorkspaceCardView` per project with a `Divider` between cards. Only
the Local section has the trailing drop zone and drag-to-reorder support; a
Remote section instead shows a state line ("Connecting…", "Unreachable.
Retrying…", "Unauthorized: check the connection's token.") in place of cards
whenever that connection isn't `.connected`. When a remote action (open,
restart, or close) is rejected by the server, that section also shows a small
red caption from `store.lastActionError`, so the failure is visible.

The Local header's title is the one thing that comes and goes. It exists to tell
this Mac's workspaces apart from a connection's, so with no connection configured
there is no second section, the word and its chevron say nothing, and the row
keeps only its buttons (which are reachable nowhere else). Losing the chevron
loses the only way to expand the section, so a collapse stored under `"local"` is
ignored while the title is hidden rather than obeyed, and honoured again as soon
as a connection puts the chevron back. `LocalSectionHeader.resolve` decides both
halves and `LocalSectionHeaderTests` asserts them, because a stored collapse with
nothing on screen to undo it would hide every workspace. The drawing below has two
connections, so it shows the titled form; the window at the top of this file has
none, so it shows the other one.

```
┌───────────────────────────────────────────────────────────────────┐
│ ▾ Local                                              ( ⟳ )  ( + )  │  SidebarSectionHeaderView
├───────────────────────────────────────────────────────────────────┤
│ ▾ laravel-test                       origin/develop           ↑1 ↓0 │  WorkspaceCardView
│                                      origin/feature/issue-15   ↑1 ↓0 │
│   (Issue #15)  (PR #16)                                             │
│   1 failing, 1 successfull checks                                   │
│   │  > Terminal 1                                                   │
│   │  ✦ Claude Code                                                  │
│ ································· Divider ·························· │
│ ▸ api-service                                                       │  WorkspaceCardView (collapsed)
│                                                                     │
│                       (drop zone: drag a card here to move to end)  │
├───────────────────────────────────────────────────────────────────┤
│ ▾ Office Mac                                         ( ⟳ )  ( - )  │  SidebarSectionHeaderView (remote)
├───────────────────────────────────────────────────────────────────┤
│ ▾ web-app                             origin/main             ↑0 ↓2 │  WorkspaceCardView (remote)
│   │  > Terminal 1                                                   │
├───────────────────────────────────────────────────────────────────┤
│ ▾ Home Mac                                                          │
│   Unreachable. Retrying…                                            │
└───────────────────────────────────────────────────────────────────┘
```

Legend:

- Bells: `task` wires `store.onBell`, `store.onNotification` (the messages a
  program sends with `OSC 9` or `OSC 777`) and a `RemoteBellObserver` to
  `BellNotifier`, and `bells.onTap` back to `showBell(_:)`, which brings this
  window forward and then takes the same path a row click does. The 🔔 on a row is
  unrelated plumbing (`store.attention`) and shows with or without notification
  permission. See `../notifications.md`.
- `SidebarSectionHeaderView`: one per section, title, chevron, and trailing
  icon buttons. A nil title draws the buttons alone, which is the Local header
  with no connection configured. Local: refresh git status, add a project folder.
  Remote: reconnect (`store.stop(); store.start()`), remove connection
  (`remoteConnections.remove(id:)` then `remoteWorkspaces.sync()`).
  See `SidebarSectionHeaderView`.
- `WorkspaceCardView`: one per project, expanded or collapsed. See
  `WorkspaceCardView.md`. Remote cards feed data from
  `RemoteWorkspaceStore.workspaces` (`[RemoteWorkspace]` from the shared
  package), mapped onto the local `Project` and `GitInfo` types by
  `RemoteProjectAdapter.decoded(_:)`; actions that
  have no remote equivalent (rename, remove terminal, remove project, enable
  sync, apply config, process controls) are wired to no-ops. Tapping a remote
  terminal row (`onActivate`) calls `openRemoteTerminal(remoteStore, ref)`, which
  awaits `RemoteWorkspaceStore.activate(refId:)` so the serving Mac opens a
  session for the row when it has none, and then goes through `showRemote` to
  `router.show(.remote(RemoteSessionRef(connectionId: sessionId:)))` with the
  session id that call answered, never with the one the row already carried (a
  revived row gets a new one). A failed activation attaches nothing and leaves
  the reason in the section's red caption, except for the one reply that leaves
  that caption empty (a success status naming no session), which
  `remoteActivationFailureMessage` turns into the same alert a local failure
  raises, so a tap is never simply ignored. See "What the pane shows" above.
  `RemoteSectionView` is also given `isSelected`, so a remote row is marked
  exactly like a local one.
  Tapping a local terminal row (`onActivate`) calls `activate(ref, in: project)`,
  which awaits `ProjectStore.activate`, so the terminal is opened if it was gone
  and an agent is started if it had stopped. Nothing else follows: selecting the
  session is what puts its surface in the pane, and the store already did that.
- `Divider`: drawn between cards, not after the last one, in both Local and
  Remote sections.
- Drop zone: a `Color.clear` region at the bottom of the Local section that
  accepts a dragged card to move it to the end. Remote sections don't support
  reordering.
- `minWidth: 240`: the sidebar has a minimum width. It is also
  `SidebarWidth.minimum`, the floor a divider drag stops at, since the outer
  explicit width never goes below it.
- Collapse state (both the section chevron and each remote card's own chevron)
  lives in one `SectionCollapseState`, held as `@State` in `ContentView` and
  backed by `UserDefaults`, so both survive a relaunch. A section is stored under
  `"local"` or `"remote-<connectionId>"` and is overruled for the Local section
  while its header has no chevron. A remote card is stored under
  `RemoteSectionView.cardKey(connectionId:workspaceId:)`, both ids because a
  workspace id is only unique on the Mac that owns it. A remote card nobody has
  toggled starts **collapsed**, unlike a section and unlike a local card, so a
  connection serving a dozen workspaces does not fill the sidebar the moment it
  connects. The collapse is the viewing Mac's own preference and is never sent
  upstream. Local project cards persist their collapse through
  `ProjectStore.toggleCollapsed` instead.

## Overlays and alerts

The sidebar is disabled and shows a small `ProgressView` while `isBusy` (a
terminal or agent session is being opened, activated, or closed). The modifiers
sit on the sidebar rather than on the window, so the pane beside it is left
alone. A remote tap holds `isBusy` longest, since it waits for the serving
instance to answer, up to the 15 second cap on that request. `ContentView` also
hosts four alerts:

```
┌──────────────────────────────┐        ┌──────────────────────────────┐
│ Rename terminal              │        │ <error message>              │
│                              │        │                              │
│  [ Name________________ ]    │        │                    [  OK  ]  │
│                              │        └──────────────────────────────┘
│        [ Cancel ] [ Rename ] │          (store.lastError)
└──────────────────────────────┘
  (renameTarget != nil)

┌────────────────────────────────────────┐
│ Rename workspace                       │
│                                        │
│ The folder on disk keeps its own name. │
│ Clear the field to go back to that     │
│ name, or to the one in this            │
│ workspace's wietty.json.               │
│                                        │
│  [ Name______________________ ]        │
│                                        │
│                  [ Cancel ] [ Rename ] │
└────────────────────────────────────────┘
  (workspaceRenameTarget != nil)

┌────────────────────────────────────────┐
│ Arguments for Codex                    │
│                                        │
│ Typed after the agent's command. Clear │
│ the field to run it with no arguments  │
│ at all.                                │
│                                        │
│  [ --model o3________________ ]        │
│                                        │
│                     [ Cancel ] [ Add ] │
└────────────────────────────────────────┘
  (agentArgumentsTarget != nil)
```

The arguments dialog is what "Add Agent with args" opens, after the agent has been
picked from the submenu (`WorkspaceCardView.md`). Its field is pre-filled with that
agent's default arguments, so the user edits rather than retypes, and so clearing
the field is visibly the way to run the agent bare: what is typed replaces the
defaults rather than being appended to them. Confirming starts the row through
`ProjectStore.openAgent`, exactly as the plain "Add Agent" item does with the
defaults. `ContentView` holds both halves of its state, `agentArgumentsTarget` and
`agentArgumentsText`, which is why this alert lives here rather than on the card.

The workspace rename dialog is opened from the workspace header's context menu
(`WorkspaceCardView.md` covers which cards offer the item at all). Its field is
pre-filled with the name the workspace shows now, so the user edits rather than
retypes, and so clearing the field is visibly the way to undo a rename.
`ContentView` holds both halves of its state, `workspaceRenameTarget` and
`workspaceRenameText`, which is why the alert lives here rather than on the card.

Confirming hands the typed name to `ProjectStore.renameWorkspace`, which trims it
and stores it in `Project.displayName`. An empty or blank name clears the override
instead of storing one, which is the only way back to whatever the workspace would
be called without it: the `name` in its `wietty.json` if it has one, otherwise
its folder. The name is local to this Mac and never written to the workspace's
config file, because renaming must not change a file inside the user's git working
tree as a side effect. `NavBarView` shows the result, since the bar reads
`Project.name`.

The `store.lastError` alert can appear on launch, before the user has clicked
anything, and one thing sets it from the `.task`: `terminals.setupError`, which is
libghostty or the bundled helper failing to start. There is nothing to fall back
to, so that message is all the user gets and it has to say what they can do about
it.

Alongside the four alerts, `ContentView` hosts one sheet: `ConfigApprovalView`, on
`store.pendingConfigApproval`. It asks whether the shell lines in a workspace's
`wietty.json` may run, and it can also appear on launch, since `load()` reconciles
every workspace that has a file. A sheet rather than an alert because the commands
are the whole question and an alert gives a list of shell lines no room. Its binding
treats any dismissal as declining, so there is no way to run the file by accident.
See `ConfigApprovalView.md`.

The `.task` also calls `store.clearDeadSessions()`, before the monitor starts. It
never sets `store.lastError`: a PTY the app spawned cannot survive the app
quitting, so a `gt:` session id is dead on every single launch, and a notice for
that every time would be noise rather than news. The rows survive; only the ids
this build could have minted are cleared. See `ProjectStore.clearDeadSessions()`.

Update related alerts are added separately by `UpdateAlertModifier`. See
`UpdateAlertModifier.md`.
