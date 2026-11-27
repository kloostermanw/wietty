# RemoteSurfacePane

A terminal that lives on another Mac, in the main window's pane. `RightTerminalView`
shows it for a selected remote session whose connection still exists
(`Wietty/RemoteSurfacePane.swift`).

The terminal is drawn by a libghostty surface, the same kind the own pane uses. Its
`wietty-pty` helper connects to a `TerminalBridge` of its own, and the bridge's link
(`RemoteSocketLink`) is the stream from the other Mac. The view owns none of that:
`RemotePane` does, one per shown session, and `RemotePanes` (built by `TerminalStack`)
keeps them.

## Opening and closing

Appearing opens the session's pane in `RemotePanes`, disappearing closes it, one close
for one open. `RightTerminalView` keys the view by its session, so a different session
or connection is a different view: the old one closes its pane and the new one opens
another. Showing a session again after a hide makes a new pane, a new surface and a
new attach, and the server paints the current screen. Clicking the row that is already
shown changes nothing, so there is still one pane and one surface. After the session
ended, clicking its row asks the other Mac for a new session (`activate`), which has a
new id, so the ended pane closes and a new one opens. A restart does the same without
a click, see "A session that ended" below.

A connection that is gone before the pane is made shows the "Connection removed"
placeholder instead (see `ContentView.md`). A stack with no surface host or no helper
shows the stack's setup error, as the own pane does.

At quit `TerminalQuitTeardown` closes every remote pane (each stops its link and
bridge and destroys its surface) and then shuts down the stack's own terminals. After
that the registry opens nothing: a view that appears that late gets a pane that is
already closed and makes no surface.

## Layout

The surface fills the pane, in the same `SurfaceContainer` the own pane uses. It is
pinned to the top left, has the size of the grid in force when another viewer holds
it, and sits in a margin painted in the terminal's background colour (see "The local
terminal in the pane" in `ContentView.md`). While the link is down, a bar is drawn
over the top of the surface, in the window status bar's style (caption text on the bar
material, a divider under it). It covers the top of the first row while it shows. A
session that ended gets no bar: the stopped screen replaces the surface.

Over, never above: the container keeps the whole pane whether the bar shows or not.
A bar above it would make the pane shorter, so a pane that owns the grid would claim a
smaller grid when the link came back (the server's resize arrives before its snapshot,
while the bar is still there) and the full one when the bar went, two resizes on the
other Mac for a line of text; a key typed while reconnecting would claim the small grid
too; and for a pane showing a grid another viewer imposed, the bar would cut off its
bottom rows.

```
connecting, live                          reconnecting
┌────────────────────────────────┐        ┌────────────────────────────────┐
│$ ls                            │        │Connection lost. Reconnecting…  │  the bar, over
│README.md  docs/                │        │               [Reconnect now]  │  the first row
│$ _                             │        ├────────────────────────────────┤
│                                │        │README.md  docs/                │
│                                │        │$ _                             │
│                                │        │                                │
└────────────────────────────────┘        └────────────────────────────────┘

waiting                                   ended
┌────────────────────────────────┐        ┌────────────────────────────────┐
│Connection lost.   [Reconnect]  │        │              [>_]              │  the stopped
├────────────────────────────────┤        │        Terminal stopped        │  screen of a
│README.md  docs/                │        │    The process has exited.     │  local terminal,
│$ _                             │        │           [Restart]            │  no surface and
│                                │        │                                │  no bar
└────────────────────────────────┘        └────────────────────────────────┘

refused
┌────────────────────────────────┐
│                                │
│             [ϟ/]               │
│   Cannot show this terminal    │
│ The other Mac runs an older    │  the message, no button
│ Wietty. Update Wietty on that  │
│ Mac.                           │
│                                │
└────────────────────────────────┘
```

(In the window the bar's text and its button are on one line, 23 points high, over
part of the first row; they are drawn on two lines above only for width.)

## What each state draws

`RemotePaneLayout` derives it from the pane's state, and `RemoteSurfacePaneTests`
asserts it.

| state | bar, over the surface | button | the pane |
| --- | --- | --- | --- |
| `connecting` | none | none | the surface (none for one main turn, while it is made) |
| `live` | none | none | the surface |
| `reconnecting` | "Connection lost. Reconnecting…" | "Reconnect now" | the surface |
| `waiting` | "Connection lost." | "Reconnect" | the surface |
| `ended` | none | "Restart", on the stopped screen, when a row still carries the session | the stopped screen (`TerminalStoppedView`), in place of the surface |
| `refused(message)` | none | none | a `ContentUnavailableView`, "Cannot show this terminal" and the message |

Both of the bar's buttons call `RemotePane.reconnectPressed()`: in `reconnecting` it
makes an attempt now, in `waiting` an attempt now and a new two minutes of automatic
attempts. A refusal covers the other Mac refusing, a Wietty too old or newer, a
connection removed while the pane is open, and the two failures of this Mac (no surface
or no bridge, and the helper going away). There is never a button then.

## A session that ended

A session that ended on the other Mac looks and works as a terminal of this Mac that
has ended (see "The local terminal in the pane" in `ContentView.md`). Both panes draw
the one `TerminalStoppedView`: "Terminal stopped" and "The process has exited.", or
"Agent stopped" and "The agent has exited." for an agent row, and a Restart button
that is the window's default (return).

What the screen says and offers comes from the rows of the connection's last snapshot
(`RemoteStoppedContent`), and the screen observes the connection's store, so a
snapshot that arrives while it is up redraws it:

| the snapshot's rows | wording | Restart |
| --- | --- | --- |
| an agent row carries the session | "Agent stopped", "The agent has exited." | yes |
| a terminal row carries the session | "Terminal stopped", "The process has exited." | yes |
| no row carries the session | "Terminal stopped", "The process has exited." | no button |

No row carries the session when its row was closed on the other Mac, when the id is a
stale one (a notification tapped after the session was replaced), and for the moment
before the first snapshot that carries a session just opened. The other Mac can only
answer 404 to a restart of such a session, so there is no button. Clicking a row in
the sidebar is the way on from there.

The pane still holds its surface, bridge and helper until it is hidden (see "Ends" in
`docs/terminal.md`), but the surface is not shown, as a local terminal's is not. So
the last screen of a remote session that ended is not readable here, as a local one's
is not.

Restart is handed up to `ContentView.restartRemoteTerminal`, which refuses it while
the sidebar is busy and otherwise calls `RemoteWorkspaceStore.restart(sessionId:)`.
The sidebar row's restart button goes through the same function. That call does not
wait and does not answer with the new session. The other Mac closes the session and
opens a new one for the same row, so the row keeps its id and gets a new session id,
and its next snapshot says so.

Because the call cannot be awaited, a press is held instead (`RemoteRestartHolds`,
one for the window): a second press for the same session, on the stopped screen or on
its sidebar row, is dropped, and the stopped screen's button is drawn disabled, until
one of three things happens.

- The selection moves. A restart that worked ends this way, since the selection
  follows the row to its new session.
- The connection's `lastActionError` becomes a text it was not at the press, which
  means the request failed.
- 5 seconds pass (`RemoteRestartHold.duration`).

Without the hold a second Return sent a second request for a session the first had
already replaced, and its 404 stayed as a red caption under the connection for a
restart that had worked. `RemoteRestartHoldTests` asserts the rule on a clock the test
moves. What the hold does not cover:

- The sidebar row's button is not drawn disabled while its session is held. A press is
  dropped without a sign.
- A failure that leaves the same error text the connection already showed at the press
  cannot be told from no answer, so the button stays held for the full 5 seconds.
- A press later than 5 seconds after one that is still running on the other Mac goes
  out as a second request.
- Another viewer (the iPad, the browser, a second Mac) restarting the same session at
  the same moment is not known here.

The selection follows the row. `RemoteRowsObserver` hands every snapshot's rows to
`PaneRouter.remoteRowsChanged`, which remembers the rows of the last snapshot that
still had a row carrying the selected session. When a later snapshot of that
connection no longer has the session, and the row that carried it now carries another
one, the router selects that one. The view is keyed by its session, so the ended pane
closes and a pane for the replacement opens. `RemoteSelectionFollow.replacement` is
the decision, and `RemoteSelectionFollowTests` and `PaneRouterTests` assert it.

That holds whoever restarted the row: this stopped screen, the sidebar row's restart
button, another viewer, or the other Mac itself. It is what a local restart does,
which selects the replacement. What is not followed:

- A row that is gone (closed on the other Mac). The pane stays on the stopped screen,
  which then has no Restart.
- A row that carries no session. It is followed once a snapshot gives it one.
- Another connection's rows. Session ids and row ids are only unique on the Mac that
  hands them out.
- Anything while the pane shows something else (a local terminal, a log, settings).
  There is no remote selection to move then.

A restart that fails (the other Mac unreachable, or the session unknown there) leaves
the stopped screen up, with the reason in the connection's red caption in the sidebar,
and its button live again.

An edited connection (name, host, port or token) gets a new store under its old id
(`RemoteWorkspacesController.sync`). `RemoteRowsObserver` keeps the store each of its
subscriptions belongs to and subscribes again when the controller holds another one,
so the follow keeps working after an edit. `RemoteObserverTests` asserts it on a real
controller.
