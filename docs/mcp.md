# MCP server

Wietty hosts an MCP server so agents (for example Claude Code) can drive
workspaces and terminal/claude sessions. The server runs inside the app and is
backed by the live `ProjectStore`, so every result reflects what the UI shows.

## Transport

The server uses the MCP "Streamable HTTP" transport in its stateless variant
(plain JSON request/response, no sessions or SSE, which is all Wietty needs
because it sends no server-initiated messages). It binds to loopback only:

```
http://127.0.0.1:7433/mcp
```

The same server also answers `GET /tests/wait`, a plain HTTP long poll described
under "Waiting for tests".

Wietty replaces the SDK's default validation pipeline with one that only
checks `Content-Type` (the default also validates `Origin`, `Accept`, and the
protocol version). Origin validation is intentionally relaxed, because many MCP
HTTP clients omit the `Origin` header; the loopback-only bind is the mitigation.

The port defaults to 7433 and can be changed on the MCP tab of Settings. The
server restarts on the new port as soon as you change it.

### Is it running

The status bar along the bottom of the window shows the server's state
(`MCPServerStatus`): a green `MCP 127.0.0.1:<port>` once the port is bound, `MCP
starting` before that, and a red `MCP not running` when it failed, with the reason
in the tooltip. The MCP tab of Settings shows the same line in full. Running means
bound: `MCPServerHost` only reports it from Hummingbird's `onServerRunning`, so a
port somebody else holds never shows green.

Both places carry a Restart, which stops the server, waits for it to let go of its
port, and starts it again on the same one. A port change in Settings goes through
the same `MCPServerHost.restart(port:)`. One host lives as long as the window, and
each start bumps a generation that the server's callbacks are checked against, so a
server that is shutting down cannot report over the one that replaced it.

### Handshake

`initialize` is stateless, so any client can handshake against the same server
instance, and a client that reconnects can handshake again. Wietty overrides
the Swift SDK's default `initialize` handler to get this: that default latches an
internal flag on the first handshake and answers every later one with `-32600
Invalid Request: Server is already initialized`, which suits a stdio server (one
server instance per connection for its lifetime) but not a stateless HTTP
endpoint where each request can come from a different client.
`MCPServerHost.makeStartedServer` registers the override after `Server.start`,
because `start` registers the SDK's own default handlers and would otherwise put
the default back.

Wietty keeps no per-client state, so repeat handshakes cost nothing. One
caveat on concurrency: the SDK's stateless transport tracks in-flight requests by
JSON-RPC id alone, not per connection. Two requests that are in flight at the
same time and share an id will collide, and since each client numbers its own
requests independently, that is reachable with two active clients. Sequential
traffic, which is what MCP clients generate in practice, is unaffected.

## Connecting Claude Code

```sh
claude mcp add --transport http wietty http://127.0.0.1:7433/mcp

or

claude mcp add --scope user --transport http wietty http://127.0.0.1:7433/mcp
```

The app must be running for the endpoint to be reachable.

## Tools

Workspaces: `list_projects`, `get_project`, `create_project`, `delete_project`,
`select_project`.

Sessions: `list_processes`, `get_process_status`, `spawn_process`,
`spawn_agent` (claude shorthand), `send_input`, `close_process`,
`select_process`, `rename_process`, `get_process_output`, `restart_process`.

Managed processes and tests: `list_managed_processes`,
`get_managed_process_output`, `get_managed_process_status`. These are the
`processes` and `tests` a workspace declares in `wietty.json`, which are
supervised commands with a captured log rather than interactive terminals. The
id each carries is the same handle the sidebar's "Copy ID for agent" row action
copies, so a prompt can point an agent straight at another process's output. A
managed process is read only here (list, and read its recent output or status by
id); the app itself starts and supervises it.

Tests: `list_tests`, `run_test`, `run_all_tests`. `list_tests` is a tests-only
view, returning the test rows `list_managed_processes` returns without the
process ones. `run_test` runs one test by its id; `run_all_tests` runs every test
in a workspace (the selected one if `project_id` is omitted). Both return the
status each test was left in. A test runs to completion, so read its result
afterwards with `get_managed_process_status` or `get_managed_process_output`,
the same read tools a managed process uses. It is done when the status reaches
`finished` or `failed`. Rather than poll, an agent can wait for that in a
background shell (see "Waiting for tests" below). Passing a process id to `run_test` is an error: only
tests are runnable this way.

A test that is already running is left alone rather than restarted, because a
second run would otherwise report the in-flight run's result as its own.
`run_test` treats that as an error, since it started nothing. `run_all_tests`
does not (meeting one test already in flight is normal when it fans out), so
every row it returns carries `started`, saying whether this call is what launched
that test.

### Waiting for tests

Polling `get_managed_process_status` costs a turn per check, and an agent that
stops polling never learns the result. The server sends no server initiated
messages, so instead it answers a plain HTTP long poll beside `/mcp`, on the same
loopback only port:

```
GET http://127.0.0.1:7433/tests/wait?id=<test-id>[&id=<test-id>...]&timeout=<seconds>
```

It is not an MCP tool. An agent starts its tests with `run_test` or
`run_all_tests`, then runs the wait as a background shell command (in Claude Code,
a Bash call with `run_in_background`), keeps working, and is notified when the
command exits:

```sh
curl -sS --fail-with-body "http://127.0.0.1:7433/tests/wait?id=<test-id>&timeout=1800"
```

The request returns as soon as no listed test is in flight (starting, running, or
stopping), or when the timeout expires. `timeout` is in whole seconds, defaults to
600, and is capped at 3600; 0 reports the current statuses without waiting. A
repeated id is waited on once.

The body is JSON: `tests`, one row per id in the shape `list_tests` returns (`id`,
`name`, `type`, `status`, `running`, `exit_code` when failed, `project_id`,
`project_name`), and `done`, true when every test reached `finished` or `failed`.
The HTTP status carries the outcome, so `curl --fail-with-body` exits non zero for
everything but a pass:

| Status | Meaning |
|--------|---------|
| 200 | Every test finished. |
| 422 | Every test ended and at least one failed. |
| 409 | Nothing is in flight, but at least one test is idle: it was never started, or it was stopped or staled before the wait. |
| 504 | The timeout expired while a test was still running. The rows carry the current statuses. |
| 404 | An id names no test (unknown workspace or test name). The body lists them in `unknown_ids`. Nothing is waited on. |
| 400 | No id, a malformed id, a process id rather than a test id, or a timeout that is not a whole number of seconds. |

When several apply, 504 wins over 409, and 409 over 422. An idle test never blocks
the wait, so a wait cannot hang on a test nobody started. A test that already
finished or failed in an earlier run returns at once with that result, which only
matters when the wait is called without starting the test first. A test whose
definition is dropped from `wietty.json` while it runs is killed, and the wait
reports it as idle (409).

The wait is event driven: `TestSupervisor.waitUntilSettled` suspends on each
test's state changes rather than polling. If the client disconnects, the request
may still be held until its timeout, which the cap bounds.

Tools that act on one workspace fall back to the workspace set with
`select_project` when `project_id` is omitted. The `list_*` tools do not:
`list_processes`, `list_managed_processes`, and `list_tests` span every workspace
unless scoped. Send a trailing newline in `send_input` text to submit a command.

## Notes

Workspace ids are persisted, so they stay stable across app restarts. A session id
is opaque: a `gt:` id the app mints when it spawns the terminal. It is stable for as
long as that terminal lives, which is at most as long as the app runs: the terminal
is a pseudo terminal Wietty owns, so quitting ends it and a session opened in a
previous launch is gone.

What invalidates a session id is the terminal going away: the row being closed, the
command exiting, or Wietty quitting. The id then
resolves to nothing, the app drops or reopens the row, and tools that target it
report that the session was not found. A client that caches session ids should
treat "not found" as "re-list", not as a transient error to retry.

A managed process or test id is a different shape:
`<workspace-id>:process:<name>` or `<workspace-id>:test:<name>`. Unlike a session,
a managed process has no minted handle. Its identity is the workspace, the kind,
and the name it has in `wietty.json`. The kind and name come from the file and the
workspace id is a persisted `Project` id, so none of the three is tied to a running
instance and the id is stable across app restarts. A process and a test may share a
name without colliding. It stops resolving when the workspace is removed, or when the
definition is dropped from `wietty.json` and the process is not still alive (a
running process whose definition is dropped is kept as `orphaned` and keeps resolving
until it stops).
