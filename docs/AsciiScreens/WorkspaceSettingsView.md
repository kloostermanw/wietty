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
│  Group                                            │
│    [ Work            ▾ ]                          │
│    Pick the group this workspace belongs to.      │
│                                                    │
│  Shell init                                       │
│    ┌────────────────────────────────────────┐    │
│    │ export PATH=$HOME/bin:$PATH             │    │
│    └────────────────────────────────────────┘    │
│    [ Revert ]                        [ Save ]     │
│                                                    │
│  Agents                                     Add   │
│    [default] Claude 1                    ✎  🗑    │
│      claude                                       │
│                                                    │
│  Terminals                                  Add   │
│    Terminal 1                            ✎  🗑    │
│                                                    │
│  Processes                                  Add   │
│    web                          long_running ✎ 🗑 │
│      npm run dev                                  │
│                                                    │
│  Tests                                      Add   │
│    unit                                  ✎  🗑    │
│      phpunit                                      │
│                                                    │
└──────────────────────────────────────────────────┘
```

Each list section (Agents, Terminals, Processes, Tests) is a `ListSettingsSection`:
the title on the left and an Add button on the right, then the rows, each with a
pencil and a trash icon. The add form is hidden until it is needed. It appears when
the list is empty (there is nothing to do but add the first item) or when Add is
pressed, and folds away again on a successful add or on Cancel. When shown it sits in
a bordered box, set apart from the rows above it. Pressing Add on the "Agents"
section, say, reveals the slot, type, prefix and fixed-naming fields below the rows:

```
│  Agents                                  Cancel   │
│    [default] Claude 1                    ✎  🗑    │
│      claude                                       │
│    ┌────────────────────────────────────────┐    │
│    │ [ Slot ] [ Type ] [ Prefix ] ( ) Fixed │    │
│    │ [ Add agent row ]                       │    │
│    └────────────────────────────────────────┘    │
```

The same component is used by the app Settings lists (Groups, Agents, Prompt
templates, Remote connections; see SettingsView.md), so the two behave alike. Shell
init is not a list, so it keeps its always-visible editor with Save and Revert.

When sync is off (no `wietty.json`), everything below Group is replaced by one
"Config file" section: a caption and an "Enable config sync" button
(`WorkspaceSettingsView.enableSyncTitle`) that calls `store.enableConfigSync`, which
writes the file from the workspace's current rows and then reveals the editors.

```
┌─ pane ───────────────────────────────────────────┐
│  Group                                            │
│    [ None            ▾ ]                          │
│  Config file                                      │
│    This workspace has no wietty.json yet...       │
│    [ Enable config sync ]                         │
└──────────────────────────────────────────────────┘
```

### Group (machine-local)

The picker (`WorkspaceSettingsView.groupBinding`) lists "None" and then one entry per
`store.groups`, and choosing one calls `store.assignGroup`, which saves the
assignment to `~/.config/wietty/config` as `workspace.N.group-id` (see
settings-storage.md). "None" leaves the workspace in no group, so it shows only under
"All" in the app menu's Group submenu; picking a real group is what the submenu
filters the sidebar down to (see ContentView.md). The group list is made and renamed
in Settings › General (see SettingsView.md); when it is empty the picker offers only
"None" and a caption points there. Which group a workspace is in is local to this
machine, like its in-app name, so it is set here rather than written into the
workspace's `wietty.json`.

### The `wietty.json` sections

Everything under Group edits the workspace's committed `wietty.json`: its
workspace-wide `shell_init`, its agent and terminal rows, and its supervised
processes and run-to-completion tests. Each section follows the same editable-list
idiom the app's Settings tabs use (see SettingsView.md): a row per item with a pencil
and a trash icon, a reading summary that becomes an inline form when the pencil is
clicked, and an add form at the bottom. The multi-value fields (`env` as
`KEY=VALUE` lines, `shell_init` and `restart_when_changed` as one entry per line)
are edited as text through `ConfigTextEditor`, parsed by `ConfigFieldText`.

These edits are the reverse of the read path documented in wietty-json.md. Each row's
save calls a `ProjectStore` mutator (`setShellInit`, `addProcess`/`updateProcess`/
`removeProcess`, the `Test` equivalents, `addAgentRow`/`addTerminalRow`/
`updateConfigRow`), which changes the live `Project`, rebuilds the
file through `ConfigReconcile.config`, and writes it. Because a `wietty.json` runs
shell lines, the store also agrees to the lines the config now runs on the user's
behalf (`ConfigTrust`, via `commitConfigEdits`): typing a command on this page is the
consent the config-approval prompt would otherwise ask for, the same standing
`enableConfigSync` already relies on (see ConfigApprovalView.md). So an edit made here
never re-raises that prompt.

Two rules carry over from the read path. An agent row's `type` (the line it runs) is
editable only while the row is idle, because a running session keeps the line it was
started with; the field is disabled with a hint on an open row, matching
`ConfigReconcile.apply`. And a slot or a process/test name must stay unique, so a
colliding rename is refused and the row stays in edit mode with a red note rather
than silently dropping the change.

The section titles are statics on the view (`WorkspaceSettingsView.groupSectionTitle`,
`.shellInitSectionTitle`, `.agentsSectionTitle`, `.terminalsSectionTitle`,
`.processesSectionTitle`, `.testsSectionTitle`, `.enableSyncTitle`, plus `.noGroupTitle`
and `.systemImage`) for the same reason `SettingsTab` is a pure type: what a screen
says is a fact about the app, and a fact about the app belongs in CI
(`WorkspacePaneTests`, `WorkspaceConfigEditorViewTests`).

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
