# The `wietty.json` File

Each workspace can hold one `wietty.json` in its root folder. It is the per
workspace configuration file: it names the workspace, lists the terminals and
Claude agents to lay out, and declares the supervised processes and
test-processes Wietty runs.

This document covers the file format and how the file is created and maintained.
For how processes actually behave once declared (kinds, status dots, the log
window, environment and PATH), see the "Processes" section of the top level
`README.md`.

## Location and naming

The file lives at the root of the workspace folder:

```
<workspace>/wietty.json
```

The filename is fixed. A workspace with no `wietty.json` still works; it just
has no persisted layout and no processes.

### Coming from itermplex

Before the product was renamed, this file was `itermplex.json` and the terminals
key was `iterm`. Neither old name is read any more, and there is no migration: a
workspace still holding an `itermplex.json` looks to the app like a workspace with
no configuration at all, and a file that still uses `iterm` fails to parse because
a required key is missing. Rename the file, rename the key, and the contents carry
over unchanged.

The two cases fail differently, and only one of them says anything. A leftover
`itermplex.json` is silent, because a workspace with no `wietty.json` is a
supported state and the app cannot tell the two apart. A `wietty.json` that still
uses `iterm` raises an alert naming the workspace and the key:

```
genotool: wietty.json is missing the required "terminals" key. A workspace
written before the rename lists its terminals under "iterm". Rename that key
to "terminals".
```

Commands in the file that referred to `$ITERMPLEX_*` variables need renaming too.
They are `$WIETTY_*` now, and an unrenamed one expands to nothing rather than
failing. See [Variables](#variables).

## How Wietty uses the file

The file is the source of truth. Wietty reads it and reflects it in the
workspace card.

- **Terminals and agents are kept in sync.** When a file exists (sync is on), the
  app writes the file to mirror the workspace's current rows, and it applies edits
  you make to the file back into the layout.
- **Processes are read only in the app.** You declare them in the file; the app
  never edits process definitions. It preserves the processes it last read when it
  rewrites the file for terminal or agent changes, so processes you add by hand are
  not lost.

When you edit the file on disk, a file watcher notices and the workspace card shows
a change indicator. Clicking it applies the change: new processes appear, removed
ones are dropped, and changed commands take effect on the next start.

The app writes the file pretty printed, with sorted keys and a trailing newline, so
it stays stable and diff friendly. Array order (agents, terminals) is preserved as
written.

## Creating the file (build)

There are two ways to get a `wietty.json`:

1. **Let the app create it.** Enabling sync for a workspace writes a fresh
   `wietty.json` from the workspace's current terminals and agents. From then on
   the app keeps it in sync.
2. **Write it by hand.** Create the file in the workspace root with the keys below.
   The app picks it up (sync is considered on whenever the file exists) and starts
   watching it.

A minimal file:

```json
{
  "agents": [],
  "terminals": [],
  "processes": {},
  "tests": {},
  "shell_init": []
}
```

## Top level keys

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string | folder name | Display name for the workspace card. A name typed into "Rename workspace…" is stored locally and wins over this one. |
| `agents` | array | `[]` | Claude agent sessions to lay out, in order. |
| `terminals` | array | `[]` | Terminal sessions to open, in order. |
| `processes` | object | `{}` | Supervised processes, keyed by name. |
| `tests` | object | `{}` | Test-processes, keyed by name (run-to-completion checks). |
| `shell_init` | array | `[]` | Shell lines run before every process and test command. |

### `name`

Optional. Overrides the workspace card title. When absent, the folder name is used.

### `agents`

An ordered list of Claude agent rows. Each entry is an object:

```json
"agents": [
  { "slot": "Design the sync feature", "type": "claude" }
]
```

| Field | Type | Meaning |
| --- | --- | --- |
| `slot` | string | The row's stable label and identity. |
| `type` | string | The agent kind. Currently `claude`. |

### `terminals`

An ordered list of terminal rows. Each entry is a plain string, the row's label:

```json
"terminals": [ "Terminal 1", "server logs" ]
```

### `processes`

An object keyed by process name. Each value is a process definition. Full field
reference:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `command` | string | required | The command to run, in the workspace directory. |
| `kind` | string | `long_running` | One of `long_running`, `daemon`, `short_running`. |
| `stop` | string | none | A command that shuts the process down. |
| `status` | string | none | Daemon only. An exit code based probe command. |
| `auto_start` | bool | `false` | Start the process when the workspace loads. |
| `auto_restart` | bool | `false` | Restart on unexpected exit (long_running only). |
| `restart_when_changed` | array | `[]` | Paths to watch (not yet implemented). |
| `env` | object | `{}` | Extra environment variables. |
| `allow_empty_vars` | bool | `false` | Run even when a referenced `WIETTY_*` variable has no value. |
| `shell_init` | array | `[]` | Extra shell lines for this process, appended after the workspace wide `shell_init`. |

Example:

```json
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
```

See the README "Processes" section for how each kind runs, the status dot, the log
window, and the shell environment.

### `tests`

An object keyed by test name. Each value is a test definition: a run to
completion check with no `kind`, `stop`, `status`, or `auto_start`. Exit code
0 means the test passed; any non zero exit code means it failed. Field
reference:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `command` | string | required | The command to run, in the workspace directory. |
| `env` | object | `{}` | Extra environment variables. |
| `allow_empty_vars` | bool | `false` | Run even when a referenced `WIETTY_*` variable has no value. |
| `shell_init` | array | `[]` | Extra shell lines for this test, appended after the workspace wide `shell_init`. |

Tests are not shown as rows. They appear in the workspace card as a single
line of buttons, one per test plus a trailing `ALL` button. A button's border
color reflects the outcome of its last run: green for passed, red for failed,
and neutral (gray) when the test has never run or has gone stale. A spinner
overlays the button while that test is running. Clicking a button runs that
test; clicking `ALL` runs every test in parallel. Right clicking a button
opens a context menu with Run, Cancel (while the test is running), and Open
log, which opens the same log window used for processes.

A passing (green) test goes stale (back to neutral) when the working tree
changes, since its result no longer reflects the current code. Staleness is
computed from a fingerprint of `git status` plus `git diff`, respecting
`.gitignore`, refreshed on the app's fast poll tier while the card is
expanded. A failing (red) test keeps its red state until it passes again;
only a pass can be invalidated by a working tree change.

Known limitation: editing the contents of an already untracked file does not
mark tests stale, because git reports an untracked file only as `?? path`
regardless of what changed inside it. Adding or removing an untracked file
does change the fingerprint and does mark tests stale.

Example:

```json
"tests": {
  "php-cs-fixer": { "command": "php-cs-fixer fix -v --dry-run" },
  "phpstan": { "command": "vendor/bin/phpstan analyse" },
  "rector": { "command": "vendor/bin/rector --dry-run" },
  "phpunit": { "command": "php artisan test" }
}
```

### `shell_init`

An ordered list of shell lines run in the same shell as the command, before it. Use it for
environment setup that the `env` map cannot express, because `env` values are set verbatim and never
shell evaluated:

```json
"shell_init": [
  "export EDITOR='vim'",
  "export PATH=$HOME/bin:$PATH",
  "source ~/bin/env.sh"
]
```

The workspace wide key applies to every process and every test. A process or test may add its own
`shell_init`, which is appended after the workspace wide lines rather than replacing them, so a
shared `PATH` stays in effect while one process layers something on top:

```json
{
  "shell_init": ["export PATH=$HOME/bin:$PATH"],
  "processes": {
    "worker": {
      "command": "python worker.py",
      "shell_init": ["source ./.venv/bin/activate"]
    }
  }
}
```

That worker runs `export PATH=$HOME/bin:$PATH`, then `source ./.venv/bin/activate`, then
`python worker.py`, all in one shell.

Details worth knowing:

- The lines are shell code, passed through unquoted. That is what makes `$HOME`, `$PATH`, and
  `source` work at all, and it is the difference between this key and `env`. The lines run inside the
  same subshell as the command, so a line of your own that runs `exit`, or `set -e` ahead of a line
  that then fails, will skip the command that follows.
- The prelude also runs before a process's `stop` and `status` commands. A `status` probe that could
  not find the binary its own process found would report a false negative.
- Lines run one after another, not chained with `&&`, so a line that fails does not by itself stop
  the command from running. Whether it stops is up to your shell (`zsh` and `bash` print and carry on
  after a failed `source`, while a POSIX `sh` aborts on a failed `.`) and to the caveat above about
  `set -e`. For `command` and `stop`, the failing
  line's complaint appears in the process log along with the command's own output. A `status` probe's
  output is not application output and is not streamed, so it is captured instead and written to the
  log only when the probe fails, on the following poll once its output has drained. A failed probe
  leaves the daemon idle, which draws the same neutral gray dot as a service that is genuinely down,
  so that captured output is the only thing that tells a broken prelude line apart from a service
  that really is not running.
- `env` values are set before the shell starts, so a prelude line can build on them, for example
  `export PATH=$MY_TOOLS:$PATH`.
- `WIETTY_*` variables can be referenced here too, and the same blocking rules apply (see
  Variables below). Note that a workspace wide line referencing a variable with no value blocks
  every process and test in the workspace that has not set `allow_empty_vars`, not just one. There is
  no workspace wide opt out.
- Blank entries are ignored, so a stray `""` in the list is harmless.
- Terminal and agent sessions are unaffected. Those run your real interactive shell, which already
  sources `~/.zshrc`.

## Variables

Wietty injects workspace variables into every process as environment variables
under the `WIETTY_` prefix. Reference them in `command`, `stop`, and `status`
with normal shell syntax (`$WIETTY_BRANCH` or `${WIETTY_BRANCH}`); the login
shell expands them when it runs the command.

The same injection and blocking rules apply to a test's `command`: a test can
reference any `WIETTY_*` variable, and `allow_empty_vars` controls whether
a missing one blocks the run or expands to empty, exactly as it does for a
process.

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
rather than run with the variable expanding to empty. This guards all three shell
run strings, each in the way that fits it: a `command` reference marks the process
failed with a message naming the missing variables; a `stop` reference blocks the
stop command so it never runs against an empty target (a live process is signaled
down instead, SIGINT then SIGTERM then SIGKILL, while a process with no live
handle, typically a daemon whose start command already exited, is marked stopped
without running its teardown); and a `status` probe reference is skipped so it
does not misreport health. Set `"allow_empty_vars": true` on the process to opt
into running any of them anyway, in which case an unavailable variable expands to
an empty string like any unset shell variable.

The check covers the `shell_init` lines that run with each of those strings, so a typo in a prelude
line is caught the same way a typo in the command is.

Expansion happens in the shell that runs `command`, `stop`, and `status`, so it
does not apply to literal values in the `env` map (those are set verbatim, not shell
evaluated).

## Full example

```json
{
  "name": "Payroll API",
  "agents": [
    { "slot": "Design the sync feature", "type": "claude" }
  ],
  "terminals": [
    "server logs"
  ],
  "processes": {
    "dev": {
      "command": "npm run dev",
      "kind": "long_running",
      "auto_start": true,
      "auto_restart": true
    },
    "open-pr": {
      "command": "gh pr view $WIETTY_PR_NUMBER --web",
      "kind": "short_running"
    },
    "tower": {
      "command": "gittower $WIETTY_WORKSPACE_PATH",
      "kind": "short_running",
      "allow_empty_vars": true
    }
  },
  "tests": {
    "phpstan": { "command": "vendor/bin/phpstan analyse" },
    "phpunit": { "command": "php artisan test" }
  },
  "shell_init": [
    "export EDITOR='vim'",
    "export PATH=$HOME/bin:$PATH",
    "source ~/bin/env.sh"
  ]
}
```
