# Wietty

Wietty is a macOS app that manages your development workspaces. Each workspace is a project
folder, shown as a card with its git status, issue and PR links, CI checks, terminals, Claude
agents, and supervised processes. Clicking a row shows its terminal in the pane beside the sidebar.
Per workspace configuration lives in a `wietty.json` file that the app reads (and, for terminals
and agents, keeps in sync).

Terminals run inside Wietty. Each one is a pseudo terminal the app owns, rendered by Ghostty,
which needs nothing installed: no iTerm2, no tmux, not even Ghostty.app. They do not survive quitting
the app, so every row's session is cleared on launch and reopens on the next click. If you have a
Ghostty configuration file, its font, theme, cursor, and keybindings are used here too. See
`docs/terminal.md`.

## Bell notifications

A terminal or agent that rings the bell marks its row with a 🔔 and posts a macOS notification
saying which workspace and which row rang. Clicking the notification brings Wietty forward and
shows that terminal, the same as clicking the row. Sessions on a connected Mac notify too, with that
connection's name in the notification.

A program can also ask for a notification by name, with the `OSC 9` or `OSC 777` escape sequence,
and then the banner carries the words it sent instead of "rang the bell". That is how coding agents
announce that they are waiting on your input.

Permission is asked for the first time something rings rather than at launch, and macOS keeps its own
per app switch under System Settings → Notifications. One notification is posted per row until the
row is visited, so a shell beeping at an ambiguous tab completion cannot flood Notification Center,
and visiting a row takes its notification back. A message a program sent is posted every time,
because it is deliberate and the second one says something the first did not. Nothing is posted
about a terminal already on screen in front of you. Settings → Notifications shows whether macOS
allows any of this, posts a test notification, and picks the sound.
See `docs/notifications.md`.

## Build

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen). `project.yml` is the source
of truth for the Xcode project; `Wietty.xcodeproj/` is generated and gitignored.

```sh
brew install xcodegen   # once

xcodegen generate

xcodebuild -scheme Wietty -destination 'platform=macOS' build
xcodebuild -scheme Wietty -destination 'platform=macOS' test
```

## Processes

Processes are named commands, declared in a workspace's `wietty.json`, that Wietty runs and
supervises in the workspace directory. Unlike terminals and agents (which Wietty only drives,
wherever they run), a process is owned by Wietty: it starts the command, tracks its state and
exit code, streams its output into a per process log window, and can stop, restart, or kill it.

Process definitions are read only in the app. The file is the source of truth. Editing
`wietty.json` surfaces the change indicator on the workspace card; clicking it applies the
change (new processes appear, removed ones are dropped, changed commands take effect on the next
start).

### Configuration

Processes live under a `processes` key, keyed by name:

```json
{
  "processes": {
    "queue": {
      "command": "cd src && sail artisan queue:work",
      "kind": "long_running",
      "auto_start": true
    },
    "sail": {
      "command": "cd src && sail up -d",
      "kind": "daemon",
      "stop": "cd src && sail down",
      "status": "cd src && sail ps | grep -q Up"
    },
    "phpunit": {
      "command": "vendor/bin/phpunit tests",
      "kind": "short_running"
    }
  }
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `command` | string | required | The command to run, in the workspace directory. |
| `kind` | string | `long_running` | One of `long_running`, `daemon`, `short_running`. |
| `stop` | string | none | A command that shuts the process down. |
| `status` | string | none | Daemon only. A probe command (see Status command below). |
| `auto_start` | bool | `false` | Start the process when the workspace loads. |
| `auto_restart` | bool | `false` | Restart on unexpected exit (see Limitations). |
| `restart_when_changed` | array | `[]` | Paths to watch (see Limitations). |
| `env` | object | `{}` | Extra environment variables. |
| `allow_empty_vars` | bool | `false` | Run even when a referenced `WIETTY_*` variable has no value (see Variables). |
| `shell_init` | array | `[]` | Extra shell lines for this process, appended after the workspace wide `shell_init` (see Environment and PATH). |

### Kinds and controls

Every process offers start, stop, restart, and kill from the row's context menu.

- **short_running**: runs to completion (for example a test or lint run). Its state becomes the
  exit result: passed on exit 0, failed on a non zero exit. Killable while running.
- **long_running**: a foreground process (for example `npm run dev`), tracked while it runs.
  Stop runs the `stop` command if one is set, otherwise it sends a signal escalation (SIGINT,
  then SIGTERM, then SIGKILL). Kill sends SIGKILL immediately.
- **daemon**: a process that detaches and returns (for example `sail up -d`, `vagrant up`). Its
  start command may exit right away while the real service keeps running, so a `stop` command is
  effectively required to bring it down, and a `status` command is recommended so the app can
  tell whether it is up.

### Status dot

Each process row shows a status dot with two independent parts. Fill encodes liveness (filled
means running, open means not running). Color encodes outcome (green means success or healthy,
red means failed or crashed, gray means neutral).

| State | Dot |
| --- | --- |
| running (long_running alive, or daemon up) | filled green |
| short task passed (exit 0) | open green |
| failed or crashed (non zero exit) | open red |
| idle, never run, or stopped | open gray |

### Status command (daemon only)

For a daemon, Wietty learns whether the service is up by running the `status` command. The
contract is exit code based:

- Exit 0 means the daemon is up (running, filled green dot).
- Any non zero exit means it is down (idle, open gray dot).

The probe's own output never decides health, and it is not streamed to the process log the way
`command` and `stop` output is. It is captured, and written to the log only when the probe fails, on
the following poll (by which point the output has drained). A failing probe leaves the same neutral
gray dot as a service that is genuinely down, so that captured output is what tells the two apart,
for example when a `shell_init` line is what actually broke (see Environment and PATH).

Write a fast, non interactive shell one liner that succeeds when the service is up and fails when
it is down. The common idiom pipes a status check into `grep -q`, which exits 0 on a match:

```json
"status": "cd src && sail ps | grep -q Up"
"status": "vagrant status --machine-readable | grep -q ',state,running'"
"status": "docker compose ps --status running | grep -q ."
```

The probe runs when an `auto_start` daemon is applied, and on the periodic refresh cycle (the
same cadence the git status refresh uses). It does not re probe immediately after a manual start
or stop; the dot updates on the next refresh.

### Output

Click a process row to open its log window: a resizable, read only, auto scrolling view of the
process output. The log is an in memory buffer capped at roughly the last 5000 lines and is
cleared when the app quits.

### Environment and PATH

Each command runs under a login, non interactive shell (`$SHELL -l -c`). This matters for
resolving tools like `sail`, `composer`, `npm`, and `vendor/bin/...`:

- Because the shell is a login shell, it sources the login startup files (for zsh: `~/.zshenv`,
  `~/.zprofile`, `~/.zlogin`, plus macOS `/etc/zprofile`, which runs `path_helper`). So your
  login PATH, including a Homebrew `brew shellenv` line in `~/.zprofile`, is available. In most
  setups no extra PATH configuration is needed.
- Because the shell is not interactive, `~/.zshrc` is not sourced. PATH entries added only in
  `~/.zshrc` will not be visible to a process. If you hit "command not found", either move that PATH
  export into a login sourced file (`~/.zprofile` or `~/.zshenv`), or put it in the workspace's
  `shell_init` (below), which keeps the setup with the project instead of in your dotfiles.

The base environment is the app's own process environment (the minimal launchd environment when
started from Finder or the Dock, or the inheriting terminal when started from one), which the
login shell then augments. The definition's `env` map is merged on top before the shell runs.

### shell_init

`shell_init` in `wietty.json` is a list of shell lines run in the same shell as the command,
before it, so its exports and `source` lines are visible to the command:

```json
{
  "shell_init": [
    "export EDITOR='vim'",
    "export PATH=$HOME/bin:$PATH",
    "source ~/bin/env.sh"
  ]
}
```

Unlike `env`, whose values are set verbatim and never shell evaluated, these lines are shell code.
That is what makes `$HOME`, `$PATH`, and `source` work here. The workspace wide key applies to every
process and test (and to a process's `stop` and `status` commands); a process or test can add its own
`shell_init`, which is appended after the workspace wide lines rather than replacing them. Terminal
and agent sessions are unaffected, since they run your real interactive shell.

See `docs/wietty-json.md` for the full field reference.

There is no dedicated PATH field. Prefer `shell_init` for PATH setup, since it runs after the login
shell has built PATH (including `path_helper`) and can extend it. Setting PATH through `env` is the
least reliable option because the login shell can rebuild it afterwards. Project local commands (for
example `vendor/bin/phpunit`, `cd src && sail ...`) avoid the question entirely.

### Variables

Wietty injects a set of workspace variables into every process as environment
variables under the `WIETTY_` prefix. Reference them in `command`, `stop`, and
`status` with normal shell syntax (`$WIETTY_BRANCH` or `${WIETTY_BRANCH}`),
and the login shell expands them when it runs the command.

```json
"processes": {
  "tower": { "command": "gittower $WIETTY_WORKSPACE_PATH", "kind": "short_running" },
  "pr":    { "command": "gh pr view $WIETTY_PR_NUMBER --web", "kind": "short_running" }
}
```

| Variable | Value |
| --- | --- |
| `WIETTY_WORKSPACE_PATH` | Absolute path of the workspace folder. |
| `WIETTY_WORKSPACE_NAME` | Workspace display name (the config `name`, else the folder name). |
| `WIETTY_BRANCH` | Current git branch. |
| `WIETTY_UPSTREAM` | Upstream tracking ref (for example `origin/feature-x`). |
| `WIETTY_BASE_BRANCH` | Base branch ref (for example `origin/main`). |
| `WIETTY_OWNER` | Repository owner. |
| `WIETTY_REPO` | Repository name. |
| `WIETTY_ISSUE_NUMBER` | Issue number parsed from the branch name. |
| `WIETTY_PR_NUMBER` | Pull request number for the current branch. |

Workspace path and name are always available. The git derived variables come from
the same status refresh the workspace card uses, so they are only as fresh as the
last refresh and are absent when unknown (a non git folder, a branch with no
upstream, no open PR, and so on).

By default, a shell command that references a variable with no value is blocked
rather than run with the variable expanding to empty. This guards all three
shell run strings, each in the way that fits it: a `command` reference marks the
process failed with a message naming the missing variables; a `stop` reference
blocks the stop command so it never runs against an empty target (a live process
is signaled down instead, SIGINT then SIGTERM then SIGKILL, while a process with
no live handle, typically a daemon whose start command already exited, is marked
stopped without running its teardown); and a `status` probe reference is skipped
so it does not misreport health. Set `"allow_empty_vars": true` on the process to
opt into running any of them anyway, in which case an unavailable variable expands
to an empty string like any unset shell variable.

The guard also covers the `shell_init` lines that run ahead of each of those three
strings, so a typo in a prelude line is caught the way a typo in a command is. One
consequence is worth knowing: because the workspace wide `shell_init` runs for
every process and every test, a single line there referencing a variable with no
value blocks all of them, not just one. `allow_empty_vars` is the only way back in
and it is per process and per test, so there is no workspace wide opt out.

Expansion happens in the shell that runs `command`, `stop`, and `status` (and the
`shell_init` lines that precede them), so it does not apply to literal values in
the `env` map (those are set verbatim, not shell evaluated).

### Limitations (v1)

- `restart_when_changed` is parsed and stored, but file watching is not implemented yet, so the
  field currently has no effect.
- `auto_restart` applies to `long_running` processes only. Daemon auto restart is not implemented
  yet.
- There is no timeout on `stop` or `status` commands, so keep them fast and non interactive; a
  command that hangs will hang that step.
- Log output is not written to disk, and typing into a running process is not supported.
