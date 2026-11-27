# Settings storage

Wietty keeps its user-facing settings in one hand-editable file at
`~/.config/wietty/config`, beside `~/.config/wietty/ghostty.cfg`. The file uses the
same format as `ghostty.cfg`: `key = value`, one per line, with `#` starting a
comment. `WiettyConfigFile` reads and writes it, `SettingsKeys` names every key, and
`ProjectStore` owns the mapping between a setting and its line.

Like `ghostty.cfg`, the file is Wietty's to write and yours to read and edit. A
comment or a key Wietty does not recognise survives a write untouched, so notes you
leave in the file stay there.

## What lives in the file

Scalars (one key each):

| Key | Meaning |
|--------------------------|---------------------------------------------------|
| `show-workspace-badge`   | `true`/`false`, the pane title badge toggle |
| `bell-sound`             | the notification sound (`none`, `default`, or `named:<Sound>`) |
| `notification-source`    | where program banners come from: `osc-9-777` (the default) or `osc-7501` |
| `check-interval-fast`    | fast tier poll seconds |
| `check-interval-normal`  | normal tier poll seconds |
| `check-interval-slow`    | slow tier poll seconds |
| `sidebar-width`          | the divider position |
| `remote-enabled`         | `true`/`false`, the LAN server toggle |
| `remote-port`            | the LAN remote terminal port |
| `mcp-port`               | the loopback MCP server port |
| `scrollback-lines`       | lines of history the server keeps per terminal, 1000 to 100000 (default 10000) |
| `selected-group`         | the active group's id, or absent for "All" |
| `color-background`       | the sidebar background, a `#RRGGBB` colour |
| `color-foreground`       | the sidebar foreground |
| `color-active-workspace-background`     | the active workspace card background |
| `color-active-workspace-foreground`     | the active workspace card foreground |
| `color-active-terminal-row-background`  | the selected terminal row background |
| `color-active-terminal-row-foreground`  | the selected terminal row foreground |
| `color-pill-background`  | the Issue/PR pill background |
| `color-pill-foreground`  | the Issue/PR pill foreground |

Each colour key is present only when that colour is set. An absent key means "leave
the default", which is what an untouched install has and what deleting the line
returns to. These are Wietty's own UI colours (`SidebarColors`). The terminal's own
colours are libghostty's to apply, so they live in `ghostty.cfg` rather than here (see
"What does not live in the file" below).

`scrollback-lines` is how much history each terminal's screen model keeps, which is
the history a viewer on another device is sent when it attaches. The pane of another
Mac and the browser page can scroll back through it; the iPad is sent it and shows
the screen only. It costs memory: about 1 KiB
per line once a terminal has filled it, so the default of 10,000 lines is about 10 MiB
per terminal and the maximum of 100,000 about 100 MiB. A value outside 1,000 to
100,000 is brought to the nearer end when the file is read, and one that is not a
number reads as the default. A change applies to terminals opened afterwards. Its
control is the "Scrollback" stepper in Settings, General, under "Terminal history"
(see `docs/AsciiScreens/SettingsView.md`). A value typed into the file by hand need
not be a multiple of 1,000: it is kept and shown as it is, opening Settings does not
rewrite it, and a click on the stepper moves it to the next multiple of 1,000 in that
direction (1,500 goes up to 2,000 and down to 1,000). The setting does not bound the
history this Mac's own pane scrolls through, nor what the pane of a terminal on
another Mac keeps: both are the surface's, sized by Ghostty's `scrollback-limit` (in
bytes) in your Ghostty configuration, a key Wietty never writes. At the default and
above it does not decide how far an MCP read reaches either, since
`get_process_output` returns at most 200 lines; set near the floor it can shorten a
read of long, wrapped lines (see terminal.md, "Reading a terminal's output").
Like the
ports, the line is written at its default too, so a file from before the setting
existed reads as 10,000 and gains this one line, under `mcp-port`, the next time
anything is saved. See terminal.md, "The server's own terminal".

Lists are flattened into indexed keys:

- **Agents** the workspace menu can start: `agent.0.name`, `agent.0.command`,
  `agent.0.args`, then `agent.1.*`, and so on.
- **Groups** a workspace can be filed under: `group.0.id`, `group.0.name`, then
  `group.1.*`, and so on. A group is one entry in the app menu's Group submenu, added
  and renamed in Settings › General. Which group is active is the `selected-group`
  scalar above, and it is dropped to "All" on load unless a group here still answers to
  it.
- **Workspaces** (the open workspace list): `workspace.0.path` (a plain folder path,
  not a security-scoped bookmark), plus `workspace.0.id`, `workspace.0.name` (the
  in-app rename, present only when set), `workspace.0.group-id` (the group it is filed
  under, present only when assigned), `workspace.0.collapsed`,
  `workspace.0.terminal-seq`, `workspace.0.claude-seq`, and `workspace.0.window-id`
  (present only when set). Each workspace's rows follow as
  `workspace.0.terminal.0.label`, `.kind`, `.slot`, `.command` (present only when the
  row carries one), `.session-id` (present only when non-empty), `.fixed-naming`
  (present only when the row pins its name to its slot) and `.prefix` (present only
  when set). The last two are agent row naming, described in wietty-json.md.
- **Approved commands** per workspace: `approved.<workspace-uuid>.0`,
  `approved.<workspace-uuid>.1`, and so on, one per line the user agreed to run.

## What does not live in the file

The file is plaintext, so no secret is ever written to it.

- The **remote access token** stays in `UserDefaults` (`wietty.remote.token`).
- Each remote **connection token** stays in the Keychain (see remote-access.md).
- **Runtime and UI state** stays in `UserDefaults`: sidebar section collapse
  (`SectionCollapseState`), update check state (`UpdateService`), and remote
  connection metadata (`wietty.remote.connections`).
- **Prompt templates** are not in this file. Each is its own markdown file under
  `~/.config/wietty/prompt_templates/`, because a template body is multi-line and this
  file holds one value per line. `PromptTemplateFile` reads and writes that directory
  and `PromptTemplateStore` owns the list. See prompt-templates.md.
- **`desktop-notifications`** already lives in `ghostty.cfg`, written by
  `GhosttyOverrideFile`, and is unchanged (see notifications.md).
- **The terminal's colours** (`background`, `foreground`, `cursor-color`,
  `cursor-text`, `selection-background`, `selection-foreground`) also live in
  `ghostty.cfg`, written by the same `GhosttyOverrideFile` and driven by
  `GhosttyColorSettings`. Only libghostty can apply them, so they go in the file it
  loads. The `color-*` keys above are the separate set for Wietty's own sidebar.

## Workspaces are plain paths

Wietty is not sandboxed, so a folder path is enough to reach a workspace and no
security-scoped bookmark is needed. The tradeoff is that a workspace is not
relinked automatically when its folder is moved or renamed on disk: the path in
the file is what Wietty opens.

## Reading, writing, and migration

The file is read once at launch and is the source of truth from then on. In-app
Settings changes are written straight back to it: `SettingsWriter` rewrites every
managed key on each change, asking each registered `SettingsPairSource` for its lines.
External edits you make by hand take effect on the next launch; Wietty does not watch
the file the way it watches `ghostty.cfg` and a workspace `wietty.json`.

There are two sources. `ProjectStore` owns the workspaces and everything the server
side needs (the ports, the check intervals, the scrollback limit), and `UIPreferences` owns the four that are this Mac's view of the data
rather than part of it: the sidebar width and colours, the active group, and the
notification sound. The rule that sorted them is whether the server's own behaviour
depends on the setting with no frontend attached, which is checkable today by asking
whether anything inside `ProjectStore` reads it to decide something.

One writer rather than two, because the file must not move.
`WiettyConfigFile.write` drops every managed line and appends what it is handed, so
two writers with disjoint keys would still shuffle their blocks against each other on
every write. The order the lines appear in is declared in `SettingsKeys.fileOrder`
rather than left to whichever source registered first, because the four that moved are
interleaved with the store's rather than grouped at either end.

A source also declares the scalar keys it owns. A managed scalar that no registered
source owns keeps the value the file already had, while one its owner deliberately
left out is still dropped, which is how clearing a colour removes its line. Without
that rule a write made before a source had registered deleted that source's settings,
which is not hypothetical: it happened during the work in issue #84.

On the first launch after settings moved here, the file does not exist yet.
`ProjectStore` then reads the old `UserDefaults` values, writes them to the file, and
removes those old keys so nothing reads them again and the two cannot drift. That
last step only happens once the file has been written successfully, so a migration
that could not be saved is retried on the next launch rather than losing the old
values. Deleting the file resets these settings to their defaults on the next launch,
which is the same "delete to reset" the `ghostty.cfg` override already had.

If the file is present but cannot be read (a bad encoding, a half-written file, a
permission problem), Wietty does not treat that as "no settings": it loads the
defaults so the app still opens, leaves the file exactly as it is instead of
overwriting it, and reports the problem. Fix or remove the file, then relaunch.

## Editing the file by hand

Two things to keep in mind when editing directly:

- **One value per line.** A value cannot contain a line break; Wietty refuses to save
  one rather than write a broken line.
- **Keep list indices contiguous.** The indexed lists (`agent.N.*`, `group.N.*`,
  `workspace.N.*`, and a workspace's `terminal.N.*`) are read in order and stop at the
  first missing index. Deleting `agent.1` while keeping `agent.2` drops `agent.2` on
  the next read, so renumber after removing an entry.

## The test suite never touches this file

`WiettyTests` is hosted by the app, so running the suite launches Wietty, which builds
a store with default arguments. Those defaults used to resolve to the real
`~/.config/wietty/config`, so every run rewrote the developer's own settings and
stripped the session ids of their live terminals.

Under a test host the three paths in this directory and the legacy `UserDefaults`
domain resolve into a sandbox instead. See `TestHost`: `isActive` is the one detection,
shared with the guard that stops `PTYProcessLauncher` spawning real processes, and both
the sandbox directory and the defaults suite have fixed names that are emptied as a run
starts rather than unique names that would pile up, because a test host is routinely
killed rather than allowed to exit.
