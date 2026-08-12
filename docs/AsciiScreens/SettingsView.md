# SettingsView

ASCII reference layout for `SettingsView`, kept in sync with the SwiftUI view
so the intended structure stays readable without running the app.

The view is a single `Form` with five sections: the badge toggle (unlabeled
section), "Periodic checks" (three steppers), "Ports" (two
port fields), "Remote access (experimental)" (the LAN toggle plus URL and QR
when enabled), and "Remote connections" (the list of other Wietty instances
this one connects to, plus a form to add one).

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
when the user leaves. As a window it survived until the app quit.

The form carries no width of its own: the pane's width is a divider the user
drags, and `RightTerminalView` gives the panel the same 480 x 240 floor every
other thing in the pane has. The grouped form scrolls, so a short window scrolls
the sections rather than clipping them.

```
┌─ pane ───────────────────────────────────────────┐
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
│                                                    │
│  Ports                                            │
│    MCP server                        [  7433 ]    │
│    (if the MCP server failed to start:)           │
│    ⚠ MCP server did not start: <reason>           │
│    Remote terminal                   [  7434 ]    │
│    TCP ports for the loopback MCP server and the   │
│    LAN remote terminal server. The MCP server      │
│    restarts on the new port as soon as you         │
│    change it.                                      │
│                                                    │
│  Remote access (experimental)                     │
│    ☐ Enable LAN remote terminal                    │
│    (if the server failed to start:)               │
│    ⚠ Server did not start: <reason>               │
│    (when enabled:)                                 │
│    http://192.168.1.20:7434/?token=abcd...         │
│    ┌───────────┐                                   │
│    │ ▚▚ QR ▚▚ │  140 x 140                         │
│    └───────────┘                                   │
│    Serves a browser terminal to other devices on   │
│    your local network. Anyone with this URL can    │
│    read and type into your sessions. Traffic is    │
│    unencrypted, so use it only on trusted          │
│    networks.                                        │
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

Legend:

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

- `MCP server` / `Remote terminal`: two `TextField`s (`SettingsView.portField`)
  bound to `$store.mcpPort` and `$store.remotePort`. Each value is clamped to
  `ProjectStore.portRange` (1024 to 65535) and persisted on set. `ContentView`
  restarts the affected server when a port changes.
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
