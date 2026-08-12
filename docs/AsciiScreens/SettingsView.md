# SettingsView

ASCII reference layout for `SettingsView`, kept in sync with the SwiftUI view
so the intended structure stays readable without running the app.

The view is a segmented tab control above a grouped `Form`, and the tab decides
what the form holds. Five tabs (`SettingsTab`), in this order: "General" (the
badge toggle and the three interval steppers), "Notifications" and "Agents"
(both empty for now), "Remote" (the LAN toggle, the remote terminal port, the URL
and QR, and the list of other Wietty instances this one connects to), and "MCP"
(the MCP server port). The panel opens on "General" (`SettingsTab.default`),
which is the first segment but is named rather than derived from that, so
reordering the segments does not quietly move where the panel lands. The
layouts below are in the same order as the segments.

It is drawn in the main window's pane, not in a window of its own, so what is
below fills the right column beside the sidebar (see ContentView.md). The three
ways in are the gear in the bar above the pane, the app menu's "Settings…" item,
and ⌘,, and all three go through `PaneRouter`.

There are two ways out, and there is no close button because of them. Activating a
terminal row puts that terminal back. The gear toggles, so a second click on it
closes the panel. Both are needed: the row a user reaches for is usually the row the
panel is covering, and activating an already selected terminal changes no selection,
so the selection callback that clears the other overrides never fires for it. With no
local terminal selected at all, on a fresh install or after the last one is closed,
the gear is the only way out. `PaneRouter` owns both rules and `PaneRouterTests`
asserts them.

One consequence of living in the pane: the panel is destroyed when the pane shows
anything else, so a half typed remote connection (including a pasted token) is gone
when the user leaves, and the tab is back to "General" on the way in. As a window it
survived until the app quit. Within one visit the half typed connection does survive
a look at another tab, because its state is held on `SettingsView` rather than
inside the tab's own subtree.

The form carries no width of its own: the pane's width is a divider the user
drags, and `RightTerminalView` gives the panel the same 480 x 240 floor every
other thing in the pane has. The grouped form scrolls, so a short window scrolls
the sections rather than clipping them. The tab control is outside the form and
does not scroll with it: a control that scrolled away would be gone exactly when
a user who has read to the bottom of one tab wants the next.

Five segments across a 480 point pane is roughly 90 points each, which "Notifications"
does not fit in, so the control truncates its labels rather than asking for a width
the pane cannot give. `SettingsPaneTests.theTabControlDoesNotWidenThePaneFloor`
pins that: if the control ever demanded its ideal width, the pane floor would move
and `SidebarWidth.windowMinimumWidth` with it, so one panel would change how small
the whole window can get.

## General (the tab the panel opens on)

```
┌─ pane ───────────────────────────────────────────┐
│ ┌─────────┬─────────┬────────┬────────┬───────┐   │
│ │ General │ Notifi… │ Agents │ Remote │  MCP  │   │
│ └─────────┴─────────┴────────┴────────┴───────┘   │
│ ────────────────────────────────────────────────  │
│  ☑ Show workspace name as terminal badge           │
│    Marks each terminal Wietty opens with its       │
│    workspace's name. Applies to terminals opened   │
│    after this is turned on. Currently inert:       │
│    libghostty exposes no way to set a surface's    │
│    title.                                          │
│                                                    │
│  Periodic checks                                  │
│    Fast                          15 s   [－][＋]   │
│    Normal                        60 s   [－][＋]   │
│    Slow                         300 s   [－][＋]   │
│    Seconds between checks for each tier. Which     │
│    check runs at which tier depends on context     │
│    (collapsed vs expanded workspace, pending CI,   │
│    attention). See documentation/periodic          │
│    checks.md.                                      │
└──────────────────────────────────────────────────┘
```

## Notifications and Agents

Both draw a `ContentUnavailableView` from `SettingsTab.placeholder` instead of a
form, outside the `Form` rather than as a section inside one. Notifications reads
"No notification settings yet", Agents reads "No agent settings yet". Agents is
the one drawn below; Notifications is the same layout with the other copy and a
`bell` rather than a `sparkles` glyph.

```
┌─ pane ───────────────────────────────────────────┐
│ ┌─────────┬─────────┬────────┬────────┬───────┐   │
│ │ General │ Notifi… │ Agents │ Remote │  MCP  │   │
│ └─────────┴─────────┴────────┴────────┴───────┘   │
│ ────────────────────────────────────────────────  │
│                                                    │
│                     ✦                              │
│            No agent settings yet                   │
│      Settings for the agents a workspace          │
│          starts will appear here.                  │
│                                                    │
└──────────────────────────────────────────────────┘
```

## Remote

```
┌─ pane ───────────────────────────────────────────┐
│ ┌─────────┬─────────┬────────┬────────┬───────┐   │
│ │ General │ Notifi… │ Agents │ Remote │  MCP  │   │
│ └─────────┴─────────┴────────┴────────┴───────┘   │
│ ────────────────────────────────────────────────  │
│  Remote access (experimental)                     │
│    ☐ Enable LAN remote terminal                    │
│    Port                              [  7434 ]    │
│    (if the server failed to start:)               │
│    ⚠ Server did not start: <reason>               │
│    (when enabled:)                                 │
│    http://192.168.1.20:7434/?token=abcd...         │
│    ┌───────────┐                                   │
│    │ ▚▚ QR ▚▚ │  140 x 140                         │
│    └───────────┘                                   │
│    Serves a browser terminal to other devices on   │
│    your local network, on the TCP port above.      │
│    Anyone with this URL can read and type into     │
│    your sessions. Traffic is unencrypted, so use   │
│    it only on trusted networks.                    │
│                                                    │
│  Remote connections                               │
│    Office Mac                          (✎) (🗑)   │
│    192.168.1.20:7434                              │
│    Home Mac                            (✎) (🗑)   │
│    10.0.0.5:7434                                  │
│    [ Name____________ ]                            │
│    [ Host____________ ]                            │
│    [ Port__ ]                                      │
│    [ Token___________ ]                            │
│    [ Add connection ]                              │
│    Connect to another Mac running Wietty with      │
│    its LAN remote terminal enabled. Enter the      │
│    host, port, and token shown in that Mac's       │
│    Settings.                                       │
└──────────────────────────────────────────────────┘
```

## MCP

```
┌─ pane ───────────────────────────────────────────┐
│ ┌─────────┬─────────┬────────┬────────┬───────┐   │
│ │ General │ Notifi… │ Agents │ Remote │  MCP  │   │
│ └─────────┴─────────┴────────┴────────┴───────┘   │
│ ────────────────────────────────────────────────  │
│    MCP server                        [  7433 ]    │
│    (if the MCP server failed to start:)           │
│    ⚠ MCP server did not start: <reason>           │
│    The loopback TCP port the MCP server listens    │
│    on. It restarts on the new port as soon as      │
│    you change it. See documentation/mcp.md.        │
└──────────────────────────────────────────────────┘
```

Legend:

- The segmented control is a `Picker` over `SettingsTab.allCases` bound to
  `SettingsView`'s `@State private var tab`. The selection is view state, not a
  preference: it is not persisted, and it is back to `SettingsTab.default` the
  next time the panel is opened.
- `SettingsTab` is a pure type so that which tabs the panel offers, in what order,
  and which of them are still empty are asserted in CI (`SettingsTabTests`) rather
  than only checkable by opening the panel. It is the same reason
  `NavBarView.trailingButtons` is a static function.
- Only the selected tab's subtree is built, so a render test that does not name a
  tab covers one fifth of the panel. `SettingsPaneTests.everyTabRenders` renders
  all five, and `SettingsView`'s `init` takes a `tab:` for that.
- `☑`: `Toggle("Show workspace name as terminal badge", isOn: $store.showWorkspaceBadge)`.
  When on, `ProjectStore` passes the workspace name as `badge:` to
  `TerminalService.open`. It has no effect today: libghostty exposes no way to
  set a surface's title, which the caption says outright. It stays because the
  plumbing is intact and the day libghostty gains a title setter it is one line.
- `Fast` / `Normal` / `Slow`: one `Stepper` row each (`SettingsView.intervalStepper`),
  bound to `$store.checkIntervals.fast`, `.normal`, `.slow`.
- `15 s` / `60 s` / `300 s`: the current value in seconds, shown next to each
  stepper (`CheckIntervals.default`, since these are the defaults before any
  change).
- `[－][＋]`: the native stepper control. Each press moves the bound value by
  `step: 5`, clamped to the tier's range (`CheckIntervals.fastRange`,
  `.normalRange`, `.slowRange`).

Changing a value updates `ProjectStore.checkIntervals` directly (the property
clamps and persists on set), so the new interval takes effect on the
scheduler's next tick, no restart needed.

- `MCP server` / `Port`: two `TextField`s (`SettingsView.portField`) bound to
  `$store.mcpPort` and `$store.remotePort`. They sat together under one "Ports"
  section before the tabs, which is why each now carries its own caption instead
  of sharing one. Each value is clamped to `ProjectStore.portRange` (1024 to
  65535) and persisted on set. `ContentView` restarts the affected server when a
  port changes.
- `⚠ MCP server did not start`: shown only when `store.mcpStartupError` is set
  (for example the port is already in use). `MCPServerHost` reports it through
  its `onStartupError` callback, and `ContentView.restartMCPHost` clears it
  before each restart attempt.
- `☐ Enable LAN remote terminal`: `Toggle(isOn: $store.remoteEnabled)`. Off by
  default. `ContentView` starts or stops `RemoteServer` in response.
- `⚠ Server did not start`: shown only when `store.remoteStartupError` is set
  (for example the port is already in use); it replaces the URL/QR until a
  successful restart clears it.
- The URL line and QR block appear only while the toggle is on and an active
  network interface exists. The URL is
  `http://<lan-ip>:<remotePort>/?token=<token>` (`LocalNetwork.primaryIPv4`,
  `ProjectStore.remoteToken`); the QR encodes the same URL (`QRCode.image`).
- "Remote connections": one row per `remoteConnections.connections`
  (`SettingsView.RemoteConnectionRow`), each showing the connection's name and
  `host:port` with edit (✎) and delete (🗑) buttons. Editing swaps the row for
  an inline name/host/port/token form with Cancel and Save; Save is disabled
  until name, host, and a valid port are present. Below the list, a form adds
  a new connection (`SettingsView.addConnection`); "Add connection" is
  disabled until name, host, port, and token are all filled in. Every
  add/edit/delete calls the matching `RemoteConnectionsStore` method and then
  `remoteWorkspaces.sync()`, which starts or stops the corresponding
  `RemoteWorkspaceStore` in `ContentView`'s sidebar.

See documentation/remote-access.md for the full feature description and the
security caveat.
