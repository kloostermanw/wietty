# SettingsView

ASCII reference layout for `SettingsView`, kept in sync with the SwiftUI view
so the intended structure stays readable without running the app.

The view is a segmented tab control above a grouped `Form`, and the tab decides
what the form holds. Six tabs (`SettingsTab`), in this order: "General" (the
badge toggle, the groups editor, the three interval steppers, and the two colour
sections),
"Notifications" (the permission
state, a test notification, and the sound), "Agents" (the agents a workspace's
menu can start), "Prompts" (the prompt templates the ⌘P popup lists),
"Remote"
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

Six segments across a 480 point pane is roughly 80 points each, which "Notifications"
does not fit in, so the control truncates its labels rather than asking for a width
the pane cannot give. `SettingsPaneTests.theTabControlDoesNotWidenThePaneFloor`
pins that: if the control ever demanded its ideal width, the pane floor would move
and `SidebarWidth.windowMinimumWidth` with it, so one panel would change how small
the whole window can get.

The prompt-templates tab is labelled "Prompts", not "Prompt templates", for the
same reason: the six segments share the floor width, so the longer label there would
push the floor, and the whole window's minimum, wider. `SettingsFieldTests` measures
the panel unframed at the floor and `theTabControlDoesNotWidenThePaneFloor` measures
it through the pane, and both pin the floor at 480. The section header and the app
menu spell the feature out in full.

## General (the tab the panel opens on)

```
┌─ pane ───────────────────────────────────────────┐
│ ┌───────┬───────┬───────┬───────┬───────┬─────┐   │
│ │General│Notifi…│Agents │Prompts│Remote │ MCP │   │
│ └───────┴───────┴───────┴───────┴───────┴─────┘   │
│ ────────────────────────────────────────────────  │
│  ☑ Show workspace name as terminal badge           │
│    Marks each terminal Wietty opens with its       │
│    workspace's name. Applies to terminals opened   │
│    after this is turned on. Currently inert:       │
│    libghostty exposes no way to set a surface's    │
│    title.                                          │
│                                                    │
│  Groups                                           │
│    Work                                (✎) (🗑)   │
│    Private                             (✎) (🗑)   │
│    Name  [________________ ]  [ Add Group ]        │
│    A group is one entry in the app menu's Group    │
│    submenu. Pick it there to show only the         │
│    workspaces filed under it. Assign a workspace   │
│    to a group from "Edit workspace…" in its menu.  │
│                                                    │
│  Periodic checks                                  │
│    Fast                          15 s   [－][＋]   │
│    Normal                        60 s   [－][＋]   │
│    Slow                         300 s   [－][＋]   │
│    Seconds between checks for each tier. Which     │
│    check runs at which tier depends on context     │
│    (collapsed vs expanded workspace, pending CI,   │
│    attention). See docs/periodic-checks.md.        │
│                                                    │
│  Colors                                           │
│    Background                    (↺)   [ ▊ ]      │
│    Foreground                          [ ▊ ]      │
│    Active workspace background   (↺)   [ ▊ ]      │
│    Active workspace foreground         [ ▊ ]      │
│    Active terminal row backgro…  (↺)   [ ▊ ]      │
│    Active terminal row foregrou…       [ ▊ ]      │
│    Issue/PR pill background      (↺)   [ ▊ ]      │
│    Issue/PR pill foreground            [ ▊ ]      │
│    Colours for Wietty's own sidebar. A colour     │
│    left unset keeps the system default; the       │
│    reset button beside a colour clears it back.   │
│                                                    │
│  Ghostty colors                                   │
│    Background                    (↺)   [ ▊ ]      │
│    Foreground                          [ ▊ ]      │
│    Cursor                              [ ▊ ]      │
│    Cursor text                         [ ▊ ]      │
│    Selection background                [ ▊ ]      │
│    Selection foreground                [ ▊ ]      │
│    (only after a write failed:)                   │
│    ⚠ Could not save that: <reason>               │
│    Written to ~/.config/wietty/ghostty.cfg,       │
│    which Wietty loads after your own Ghostty      │
│    config so what is set here wins for Wietty's   │
│    terminals. Ghostty.app is not affected. A      │
│    colour left unset keeps your own theme's; the  │
│    reset button clears one back to that.          │
└──────────────────────────────────────────────────┘
```

The Groups section (`SettingsView.groupsSection`) is one row per `store.groups`
(`GroupRow`): the group's name with an edit `(✎)` and delete `(🗑)` button. Editing
swaps the row for an inline Name field with Cancel and Save; Save is disabled until
the name is non-blank (`WorkspaceGroup.isValid`). The Name field below the list adds
one, and "Add Group" is disabled by the same rule. With the list empty the section
says so. A group is the same preference the agents are: held on `ProjectStore`,
persisted to `~/.config/wietty/config` as `group.0.id`/`.name` (see
settings-storage.md), and never seeded, so an install with no groups shows every
workspace under "All". Deleting a group unfiles the workspaces that were in it and
clears the active selection if it was that group. Which group is active drives the app
menu's Group submenu and the sidebar filter (see ContentView.md); assigning a
workspace to one is done on its own page (see WorkspaceSettingsView.md).

The two colour sections are `SettingsView.colorsSection` and
`terminalColorsSection`. Each row is a `ColorSettingRow`: a label, a reset button
`(↺)` that appears only once a colour is set, and a native colour well `[ ▊ ]`
(`ColorPicker`, `labelsHidden`, opacity off). The reset sits between the label and
the well so a grouped form does not push it past the well.

The first section is Wietty's own sidebar colours, held on `ProjectStore`
(`SidebarColors`) and persisted to `~/.config/wietty/config` as `color-*` keys (see
settings-storage.md). A well is empty (drawing the current default) until a colour is
set; the reset clears it back to nil, which removes the line. The colours reach the
sidebar through `EnvironmentValues.sidebarColors`, set once on the sidebar in
`ContentView`: the background and foreground colour the sidebar, the active workspace
pair colours the card that owns the terminal on screen (`WorkspaceHighlight`), and the
active terminal row pair colour the selected row, the row background replacing the
built-in `#292b34` (`SidebarRowBackground.fill(activeRowBackground:)`), and the
Issue/PR pill pair colour the pills a workspace card draws for its branch's issue and
PR (`IssuePRLineView`, resolved through `IssuePRPillColors`). An unset pill background
keeps the faint accent wash and an unset foreground keeps the accent text, so an
untouched install draws the pills exactly as before.

The second section is the terminal's own colours, driven by `GhosttyColorSettings`
and written to `~/.config/wietty/ghostty.cfg` (`GhosttyOverrideFile`), the same file
`desktop-notifications` uses. A write reloads the live config, so a colour reaches
terminals already open. These wells show the value Wietty is forcing in that file, not
what an untouched terminal resolves from the user's own theme: reading a resolved
colour back from libghostty is a good deal more work than reading the boolean the
Notifications tab does, and the caption says as much.

## Notifications

Four sections (`NotificationSettings`, in `SettingsView.swift`): whether macOS lets
this app post at all, whether libghostty lets a program ask for one, a way to prove
the whole path works, and which sound it makes. See
`../notifications.md` for what the app does with a bell and with an `OSC 9`.

The order is the order the gates are passed. A notification a program asks for has
to clear libghostty's `desktop-notifications` before anything in this app sees it,
so the section that controls it sits above the test button rather than below.

```
┌─ pane ───────────────────────────────────────────┐
│ ┌───────┬───────┬───────┬───────┬───────┬─────┐   │
│ │General│Notifi…│Agents │Prompts│Remote │ MCP │   │
│ └───────┴───────┴───────┴───────┴───────┴─────┘   │
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
│  Desktop notifications from programs              │
│    Let programs post notifications        (  ●)   │
│    (OSC 9 and OSC 777)                            │
│    (only when Wietty's file and the user's own    │
│     Ghostty config disagree:)                     │
│    ⓘ Your own Ghostty config sets this to off.    │
│    Wietty is overriding it.                       │
│    (only after a write failed:)                   │
│    ⚠ Could not save that: <reason>               │
│    Turned off, a program asking for a             │
│    notification is answered by nothing: no        │
│    banner, no 🔔, and no error either. …          │
│    This writes desktop-notifications to           │
│    ~/.config/wietty/ghostty.cfg, which Wietty     │
│    loads after your own Ghostty config so what is │
│    set here wins. Ghostty.app is not affected     │
│    either way. Until you touch it your Ghostty    │
│    config decides, and deleting that file goes    │
│    back to that.                                  │
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
│ ┌───────┬───────┬───────┬───────┬───────┬─────┐   │
│ │General│Notifi…│Agents │Prompts│Remote │ MCP │   │
│ └───────┴───────┴───────┴───────┴───────┴─────┘   │
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
persisted to `~/.config/wietty/config` as `agent.0.name`/`.command`/`.args` (see
settings-storage.md), and seeded with Claude on a fresh install so the workspace menu
is not empty before anyone has been here. Seeding happens only when migrating an
install that never stored a list, never on an empty file, so deleting the last agent
sticks across a relaunch. With the list empty the section says so, and each "Add
Agent" submenu holds one disabled line pointing back here.

## Prompts

The prompt templates the ⌘P popup lists and types into the focused terminal. Each is
a markdown file in `~/.config/wietty/prompt_templates/` (see prompt-templates.md and
PromptTemplatePickerView.md). The tab reads that directory on the way in, so a file
added or edited outside the app shows without a relaunch.

```
┌─ pane ───────────────────────────────────────────┐
│ ┌───────┬───────┬───────┬───────┬───────┬─────┐   │
│ │General│Notifi…│Agents │Prompts│Remote │ MCP │   │
│ └───────┴───────┴───────┴───────┴───────┴─────┘   │
│ ────────────────────────────────────────────────  │
│  Prompt templates                                 │
│    Fix bug                             (✎) (🗑)   │
│    Investigate and propose a fix                  │
│    Refactor helper                     (✎) (🗑)   │
│    Reduce nesting                                 │
│    Name         [________________ ]               │
│    Description  [________________ ]               │
│    Argument hint (for example <ticket-id> <area>) │
│                 [________________ ]               │
│    ┌────────────────────────────────┐             │
│    │ Body: Investigate bug $1 and…  │             │
│    │                                │             │
│    └────────────────────────────────┘             │
│    [ Add Template ]                                │
│    (only after a write failed:)                   │
│    ⚠ Could not save that: <reason>               │
│    Each template is a prompt the popup types into │
│    the focused terminal, leaving the cursor there │
│    so you can edit before sending it. Use $1, $2  │
│    for values the popup asks for, and $ARGUMENTS  │
│    for all of them. Templates are markdown files  │
│    in ~/.config/wietty/prompt_templates.          │
└──────────────────────────────────────────────────┘
```

One row per `promptTemplates.templates` (`PromptTemplateRow`), each showing the
template's display name and, under it in secondary text, its description (or the
argument hint when there is no description). Editing (✎) swaps the row for an inline
Name / Description / Argument hint form plus a `PromptBodyEditor` (a `TextEditor`
with its own border and height, because the grouped form's `.roundedBorder` field
style reaches `TextField` and `SecureField` but not `TextEditor`) and Cancel / Save;
Save is disabled until the name is non-blank (`PromptTemplate.isValid`). The form
below the list adds one, and "Add Template" is disabled by the same rule. With the
list empty the section says so.

Unlike the groups and agents, a template is not a flat-config list on `ProjectStore`:
it is one markdown file, so it has its own store (`PromptTemplateStore`) over a
directory of files (`PromptTemplateFile`), and it never touches
`~/.config/wietty/config`. Adding writes a new file named from a slug of the name,
disambiguated on collision; editing rewrites the same file (identity is the file
URL); deleting removes it. See settings-storage.md and prompt-templates.md.

## Remote

```
┌─ pane ───────────────────────────────────────────┐
│ ┌───────┬───────┬───────┬───────┬───────┬─────┐   │
│ │General│Notifi…│Agents │Prompts│Remote │ MCP │   │
│ └───────┴───────┴───────┴───────┴───────┴─────┘   │
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
│ ┌───────┬───────┬───────┬───────┬───────┬─────┐   │
│ │General│Notifi…│Agents │Prompts│Remote │ MCP │   │
│ └───────┴───────┴───────┴───────┴───────┴─────┘   │
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
  tab covers one sixth of the panel. `SettingsPaneTests.everyTabRenders` renders
  all six, and `SettingsView`'s `init` takes a `tab:` for that.
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
- `Let programs post notifications`: libghostty's `desktop-notifications`, read
  through `ghostty_config_get` and written to `~/.config/wietty/ghostty.cfg`
  (`DesktopNotificationSetting`, `GhosttyOverrideFile`). It is a config file rather
  than a `UserDefaults` key because libghostty has no setter: the only way to change
  a value is to hand it another file, and Wietty's is loaded after the user's own so
  it wins. Writing is followed by `reloadConfig()`, so terminals already open take
  the new value rather than the next launch's.
- The toggle shows what libghostty resolved, not what Wietty wrote. The two differ
  whenever the user's own Ghostty config has the last word, and a toggle reading its
  own file would then disagree with the terminal it claims to describe.
- `ⓘ Your own Ghostty config sets this to …` appears only when the resolved value
  and the user's own config disagree, which is exactly when Wietty is overriding
  them. Without it a switch quietly contradicting a file they wrote reads as Wietty
  having ignored it.
- There is no control for going back to the user's own config, because that is what
  not touching the toggle already does: the file does not exist until the switch is
  first flipped, and deleting it returns to the same state. A button whose job is to
  reach the default is a button for something you get by doing nothing, and it was
  briefly there before being taken out.
- Every write strips the comments Wietty itself wrote before adding them back, so
  the file holds exactly one header however many times it is toggled. It did not,
  once: comments are preserved like any other line the user might have added, so the
  header was preserved too and prepended again, and nine toggles left nine copies of
  it. A file from that build is repaired by the next write.
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
  showing a blank selection. Persisted to `~/.config/wietty/config` under
  `bell-sound` (see settings-storage.md) and applied to the next notification. `[ Test ]` plays the selection now (`BellSound.play()`), is
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
