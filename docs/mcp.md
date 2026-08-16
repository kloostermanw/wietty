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

Wietty replaces the SDK's default validation pipeline with one that only
checks `Content-Type` (the default also validates `Origin`, `Accept`, and the
protocol version). Origin validation is intentionally relaxed, because many MCP
HTTP clients omit the `Origin` header; the loopback-only bind is the mitigation.

The port defaults to 7433 and can be changed on the MCP tab of Settings. The
server restarts on the new port as soon as you change it, and that tab shows an
error there if it fails to bind.

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
supervised commands with a captured log rather than interactive terminals, so
the surface is read only (list, and read one's recent output or status by its
id). The id each carries is the same handle the sidebar's "Copy ID for agent"
row action copies, so a prompt can point an agent straight at another process's
output.

Tools that omit `project_id` fall back to the workspace set with
`select_project`. Send a trailing newline in `send_input` text to submit a
command.

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
and the name it has in `wietty.json`, so the id is stable across app restarts (it
is derived from the file, not from a running instance) and a process and a test may
share a name without colliding. It stops resolving when the workspace is removed or
the definition is dropped from `wietty.json`.
