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
new id, so the ended pane closes and a new one opens.

A connection that is gone before the pane is made shows the "Connection removed"
placeholder instead (see `ContentView.md`). A stack with no surface host or no helper
shows the stack's setup error, as the own pane does.

At quit `TerminalQuitTeardown` closes every remote pane (each stops its link and
bridge and destroys its surface) and then shuts down the stack's own terminals.

## Layout

Top to bottom: a bar while the link is down or the session is over, then the surface
in the same `SurfaceContainer` the own pane uses. The surface is pinned to the top
left, has the size of the grid in force when another viewer holds it, and sits in a
margin painted in the terminal's background colour (see "The local terminal in the
pane" in `ContentView.md`). The bar is drawn in the window status bar's style (caption
text on the bar material, a divider under it) and takes the top 23 points of the pane,
so the surface below it is that much shorter while it shows.

```
connecting, live                          reconnecting
┌────────────────────────────────┐        ┌────────────────────────────────┐
│$ ls                            │        │Connection lost. Reconnecting…  │
│README.md  docs/                │        │               [Reconnect now]  │  the bar
│$ _                             │        ├────────────────────────────────┤
│                                │        │$ ls                            │
│                                │        │README.md  docs/                │
│                                │        │$ _                             │
└────────────────────────────────┘        └────────────────────────────────┘

waiting                                   ended
┌────────────────────────────────┐        ┌────────────────────────────────┐
│Connection lost.   [Reconnect]  │        │This terminal has ended on the  │
├────────────────────────────────┤        │other Mac.                      │  no button
│$ ls                            │        ├────────────────────────────────┤
│README.md  docs/                │        │$ ls                            │  the last
│$ _                             │        │README.md  docs/                │  screen, kept
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

(In the window the bar's text and its button are on one line; they are drawn on two
above only for width.)

## What each state draws

`RemotePaneLayout` derives it from the pane's state, and `RemoteSurfacePaneTests`
asserts it.

| state | bar | button | below the bar |
| --- | --- | --- | --- |
| `connecting` | none | none | the surface (none for one main turn, while it is made) |
| `live` | none | none | the surface |
| `reconnecting` | "Connection lost. Reconnecting…" | "Reconnect now" | the surface |
| `waiting` | "Connection lost." | "Reconnect" | the surface |
| `ended` | "This terminal has ended on the other Mac." | none | the surface, with its last screen |
| `refused(message)` | none | none | a `ContentUnavailableView`, "Cannot show this terminal" and the message, filling the pane |

Both buttons call `RemotePane.reconnectPressed()`: in `reconnecting` it makes an
attempt now, in `waiting` an attempt now and a new two minutes of automatic attempts.
A refusal covers the other Mac refusing, a Wietty too old or newer, a connection
removed while the pane is open, and the two failures of this Mac (no surface or no
bridge, and the helper going away). There is never a button then.

The bar appears and disappears with no animation. A link that keeps dropping switches
between `live` and `reconnecting`, and an animated bar would make that worse to look
at.
