# SettingsView

ASCII reference layout for `SettingsView`, kept in sync with the SwiftUI view
so the intended structure stays readable without running the app.

The view is a segmented tab control above a grouped `Form`, and the tab decides
what the form holds. Five tabs (`SettingsTab`), in this order: "General" (the
badge toggle and the three interval steppers), "Notifications" (the permission
state, a test notification, and the sound), "Agents" (the agents a workspace's
menu can start), "Remote"
(the LAN toggle, the remote terminal port, the URL and QR, and the list of other
Wietty instances this one connects to), and "MCP"
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

Every field is bordered, and that is set in one place: `SettingsView.form(_:)`, the
one grouped `Form` all five tabs draw, carries `.textFieldStyle(.roundedBorder)`.
The style travels down the environment, so it reaches every `TextField` and
`SecureField` in every tab and a field added later gets it without anyone
remembering to. Without it a grouped form draws a field as its label with the value
as plain right aligned text, with no border and no background of its own: nothing
said the value was editable, and an empty field was invisible, indistinguishable
from a caption.

A field only a few characters wide (a port, and nothing else so far) is a
`NarrowFieldRow` rather than a `.frame(width:)` on the field, which is not the same
thing: a grouped form gives up its label-left, field-right layout for a field with
a width of its own, moving the label to a line above and leaving the narrow field
under it, out of line with every other field in the section. The row keeps the
layout and narrows only what is inside it, and both port fields plus the two
connection forms share it, so the four cannot drift apart by a few points each.

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
│    attention). See docs/periodic-checks.md.        │
└──────────────────────────────────────────────────┘
```

## Notifications

Three sections (`NotificationSettings`, in `SettingsView.swift`): whether macOS
lets this app post at all, a way to prove the whole path works, and which sound it
makes. See
`../notifications.md` for what the app does with a bell and with an `OSC 9`.

```
┌─ pane ───────────────────────────────────────────┐
│ ┌─────────┬─────────┬────────┬────────┬───────┐   │
│ │ General │ Notifi… │ Agents │ Remote │  MCP  │   │
│ └─────────┴─────────┴────────┴────────┴───────┘   │
│ ────────────────────────────────────────────────  │
│  System notifications                             │
│    Permission                        ✓ Allowed    │
│    (only while nobody has been asked:)            │
│    [ Allow notifications… ]                       │
│    (only after macOS refused to even ask:)        │
│    ⚠ macOS turned the request down: <reason>     │
│    No prompt was shown, so this is not something  │
│    you answered. …                                │
│    (only after a denial:)                         │
│    Turn Wietty's notifications back on in System  │
│    Settings › Notifications. macOS asks only      │
│    once, so this app cannot ask again.            │
│    A terminal notifies you in two ways: the bell  │
│    character, which every shell rings, and the    │
│    OSC 9 and OSC 777 escape sequences, which a    │
│    program uses to send a message of its own.     │
│    That second one is how coding agents say they  │
│    are waiting on your input. …                   │
│    A Focus mode can hold banners back even when   │
│    this says Allowed. …                           │
│                                                    │
│  Test notification                                │
│    [ Send test notification ]                     │
│    (before the first press:)                      │
│    Posts one notification, so the whole path can  │
│    be checked without waiting for a terminal to   │
│    ring. …                                        │
│    (after a successful press:)                    │
│    Posted. If no banner appeared, a Focus mode    │
│    or Notification Centre is holding it back.     │
│    (after a refusal:)                             │
│    ⚠ Not posted: <reason>                        │
│                                                    │
│  Bell sound                                       │
│    Sound          [ Default   ▾ ]   [ Test ]      │
│    Played by every notification a terminal posts. │
│    "Default" is the alert sound chosen in System  │
│    Settings › Sound. "Test" plays it here; "Send  │
│    test notification" above is what checks that a │
│    banner carries it.                             │
│    (instead, when the preview had nothing to play:)│
│    ⚠ That sound could not be loaded. macOS may   │
│    no longer install it.                          │
└──────────────────────────────────────────────────┘
```

## Agents

The list a workspace's "Add Agent" submenus offer. It was the last tab that existed
ahead of its settings (Notifications was the other one), and filling it is what
deleted its placeholder, along with the placeholder machinery itself: every tab now
holds settings of its own.

```
┌─ pane ───────────────────────────────────────────┐
│ ┌─────────┬─────────┬────────┬────────┬───────┐   │
│ │ General │ Notifi… │ Agents │ Remote │  MCP  │   │
│ └─────────┴─────────┴────────┴────────┴───────┘   │
│ ────────────────────────────────────────────────  │
│  Agents                                           │
│    Claude                              (✎) (🗑)   │
│    claude                                         │
│    Codex                               (✎) (🗑)   │
│    codex --model o3                               │
│    Name                    [________________ ]    │
│    Command                 [________________ ]    │
│    Default Arguments       [________________ ]    │
│    [ Add Agent ]                                   │
│    Each agent is one entry in a workspace's        │
│    "Add Agent" menu. Starting one opens a          │
│    terminal in that workspace and types the        │
│    command, followed by its arguments. "Add        │
│    Agent with args" asks for other arguments       │
│    first, starting from the ones here.             │
└──────────────────────────────────────────────────┘
```

One row per `store.agents` (`AgentRow`), each showing the agent's name and, under
it in secondary text, the line starting it types (`AgentDefinition.launchCommand`)
rather than the command and the arguments as two separate facts. Editing (✎) swaps
the row for an inline Name / Command / Default Arguments form with Cancel and Save;
Save is disabled until both a name and a command are present
(`AgentDefinition.isValid`). The form below the list adds one, and "Add Agent" is
disabled by the same rule.

The list is a preference like the ports and the bell sound: held on `ProjectStore`,
persisted under `wietty.agents`, and seeded with Claude on a fresh install so the
workspace menu is not empty before anyone has been here. Seeding happens only when
nothing has ever been stored, never on an empty list, so deleting the last agent
sticks across a relaunch. With the list empty the section says so, and each "Add
Agent" submenu holds one disabled line pointing back here.

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
│    Name                    [________________ ]    │
│    Host                    [________________ ]    │
│    Port                              [  7434 ]    │
│    Token                   [________________ ]    │
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
│    you change it. See docs/mcp.md.                 │
└──────────────────────────────────────────────────┘
```

Legend:

- The segmented control is a `Picker` over `SettingsTab.allCases` bound to
  `SettingsView`'s `@State private var tab`. The selection is view state, not a
  preference: it is not persisted, and it is back to `SettingsTab.default` the
  next time the panel is opened.
- `SettingsTab` is a pure type so that which tabs the panel offers and in what
  order are asserted in CI (`SettingsTabTests`) rather than only checkable by
  opening the panel. It is the same reason `NavBarView.trailingButtons` is a static
  function.
- Only the selected tab's subtree is built, so a render test that does not name a
  tab covers one fifth of the panel. `SettingsPaneTests.everyTabRenders` renders
  all five, and `SettingsView`'s `init` takes a `tab:` for that.
- `☑`: `Toggle("Show workspace name as terminal badge", isOn: $store.showWorkspaceBadge)`.
  When on, `ProjectStore` passes the workspace name as `badge:` to
  `TerminalService.open`. It has no effect today: libghostty exposes no way to
  set a surface's title, which the caption says outright. It stays because the
  plumbing is intact and the day libghostty gains a title setter it is one line.
- `Permission`: what `BellNotifier.permission()` last answered, read in the tab's
  `task` on the way in rather than once per launch, because permission can be
  granted or revoked in System Settings while Wietty runs. Four states, each with
  its own glyph and colour: "Checking…" (nothing read yet), "Not asked yet",
  "Allowed" (green), "Not allowed" (red). Reading it never prompts.
- `[ Allow notifications… ]` appears only while the state is "Not asked yet".
  macOS shows the prompt once per install, so after a denial the button could do
  nothing at all, and the sentence pointing at System Settings takes its place.
- `⚠ macOS turned the request down` is the third outcome, and the reason this row
  exists: a request from a bundle macOS does not accept comes back in about a
  millisecond with an error and no prompt, leaving the state exactly as it was.
  Drawing only the unchanged state made the button look dead, which is how this
  was found. `BellNotifier.PermissionRequest` keeps that case apart from a
  denial, since only one of the two is a switch in System Settings.
- `[ Send test notification ]`: `BellNotifier.sendTest(sound:)`, which posts
  `BellNotification.test()` with the sound currently selected below. It reports
  what happened either way: `UNUserNotificationCenter` refuses to ask on behalf of a
  bundle it does not consider properly signed, and a Test button that fails silently
  answers the opposite question from the one it was pressed to answer. The test notification's
  target matches no row, so tapping it reopens the window and activates nothing.
- `Sound`: a `Picker` over `NotificationSettings.soundChoices` bound to
  `$store.bellSound`: `BellSound.offered` ("None", "Default" for the system alert
  sound, then every sound in `/System/Library/Sounds` by name), plus the stored sound
  when it is no longer installed, so the control names what is missing rather than
  showing a blank selection. Persisted under `wietty.bellSound` and applied to the
  next notification. `[ Test ]` plays the selection now (`BellSound.play()`), is
  disabled for "None", which has nothing to play, and draws a red caption when the
  file could not be loaded. It previews the file through `NSSound`; `[ Send test
  notification ]` above is the one that checks a banner carries the sound, because
  `UNNotificationSound` resolves a name differently. See `docs/notifications.md`.
- `NotificationSettings` is a view of its own because it is the only tab with state
  of its own (the permission it read, the verdict on the last test), and its `init`
  takes both for the same reason `SettingsView.init` takes a `tab:`: they decide
  four of the branches drawn here, and a render test that could not set them would
  cover one (`SettingsPaneTests.theNotificationsTabRendersInEveryState`).
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

- `MCP server` / `Port`: two `TextField`s (`SettingsView.portField`, a
  `NarrowFieldRow` around a number formatted field) bound to
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

See docs/remote-access.md for the full feature description and the
security caveat.
