# LAN remote access

Wietty instances can reach each other, and be reached from a browser, over
the local network. There are two related but separate pieces:

- **Served side.** Every instance can opt in to serving a browser based
  terminal (xterm.js) and a JSON/WebSocket control API on the LAN. This is
  what the rest of this document calls the remote server.
- **Controlling side.** A Wietty instance can also register other
  instances as "remote connections" in Settings. Each remote connection shows
  up as its own section in the sidebar, alongside the local one, with live
  workspace state and the same workspace cards used locally. This is the
  native macOS to macOS control path; it is built into Wietty itself, not
  a separate app.

Both are opt in and off by default, and both are scoped to a trusted local
network. An iPadOS client is in development, sharing the controlling side with
this app through the [wietty-shared](https://github.com/kloostermanw/wietty-shared)
package. Any client reachable outside the LAN remains future work.

## Served side: browser based remote terminal

From a second laptop, an iPad, or an iPhone on the same wifi you can open a
token protected page, see an instance's terminal sessions, attach to one, and
get a live, colored, interactive terminal. The screen streams in real time and
the keys you type reach the session.

### How to use it

1. Open Settings and turn on "Enable LAN remote terminal" in the "Remote
   access (experimental)" section.
2. A reachable URL and a QR code appear. The URL looks like
   `http://192.168.1.20:7434/?token=<token>`.
3. On another device on the same wifi, open the URL or scan the QR code.
4. The page lists this instance's workspaces and their terminal sessions. Tap
   one to attach.
5. Type in the terminal. Keys, including Ctrl+C, arrows, and tab completion,
   reach the session. Colors and screen updates render live.
6. Turn the toggle off to stop the server. Open pages can no longer connect.

If the server cannot start (for example the remote port is already in use),
the Settings section shows the error instead of a URL, so you can pick a free
port.

### Architecture

Terminals and Claude sessions are pseudo-terminals Wietty spawned itself and
libghostty renders; see `documentation/terminal.md`. **The wire format has not
changed** across the substrates this app used to ship: the browser client, the
JSON/WebSocket shapes, and `WS /attach`/`WS /control` are the same, so an existing
browser tab or iPadOS client needs no update. A session
id on the wire is whatever the serving Mac calls a terminal, and is opaque to every
client.

The path from the browser back to the terminal, in order:

- **Browser (xterm.js).** `remote_index.html` bundles xterm.js. It fetches
  `GET /api/sessions` for the session list, then opens
  `WS /attach?session=<id>&token=<t>`. It writes incoming VT bytes to the
  terminal and forwards each keystroke as `{"data":"<bytes>"}`.
- **`RemoteServer.swift`.** A Hummingbird HTTP plus WebSocket server bound to
  `0.0.0.0` on the remote port (7434 by default), separate from the loopback
  MCP server. It serves the web client, the token gated session and workspace
  listings, the token gated per session socket, and the control socket
  described below.
- **`ScreenStreaming`.** The protocol `RemoteServer` is built against. It
  declares only `attach`, `detach`, `send`, and `stop`, so the server does not
  know what is behind it, which is what lets a test back the server with a fake.
- **`PaneStreamHub.swift`.** The one producer. A session id on the wire is a `gt:`
  id the app minted. `TerminalRelay` writes every chunk of the child's own output
  into the hub, which coalesces on an 8 ms timer (a shell echoing a typed line
  emits one notification per character) and fans it out to every viewer of that
  session: the browser, the iPad, and the app's own pane all consume the same
  bytes, so a rendering fault is fixed once. Bytes are split on UTF-8 boundaries,
  so a multibyte character straddling two flushes is not cut in half. A viewer that
  attaches is painted first, from a `ScreenSnapshot` read off the surface, because
  a session sitting idle emits no output and would otherwise show a blank screen.
  When a terminal's child exits, every viewer of it receives an end signal and the
  client shows the session has ended. A viewer arriving after that already happened
  gets the same end signal on attach, because the session is checked against a live
  census first. That case is reachable from any client's sidebar: a terminal row
  outlives its terminal so it can be restarted, and a row that was configured but
  never opened carries no session id at all. Only a confirmed absence ends the
  viewer; a census that merely failed leaves the attach alone, because one
  transient error must not end a viewer whose terminal is fine.

Remote viewers do not resize anything. The grid is the libghostty surface's own,
derived from the pane in the app window, so a small phone cannot reflow the Mac
session: it letterboxes when larger and scrolls or scales when smaller. Managed
process PTYs remain outside this path; only terminal sessions are served.

### The producer

The producer is `TerminalRelay`, which owns the read
source on the pty Wietty spawned and writes every chunk into
`PaneStreamHub.write` before it writes it to the surface. **The bytes on the
wire are the child's own**, so a rendering fault is fixed once for the browser,
the iPad, and the app itself. Remote keystrokes take the same path a local one takes,
into the pty master, so both orders are the pty's. Three differences are worth
knowing on the client side:

- **`TERM` is `xterm-ghostty` when that terminfo entry is installed, and
  `xterm-256color` otherwise** (`RawPTY.terminalType`, resolved once per launch
  with `infocmp`). In practice the first case means Ghostty.app is present on
  the serving Mac. Because the served bytes are the child's own, a program
  drawing for `xterm-ghostty` can emit sequences a client does not implement:
  xterm.js in the browser page and SwiftTerm in the iPadOS client each render
  what they support and ignore the rest. Nothing translates between them.
- **The paint on attach is monochrome and its cursor is approximate.**
  `ghostty_surface_read_text` is the only read back libghostty offers and it
  carries no attributes, and the C API has no cursor getter at all, so the
  cursor is placed at the end of the last non-empty row. Both costs last one
  frame: every byte after the paint is exact.
- **The paint comes from the last recorded screen rather than the instant of
  attach**, bounded at 300 ms (`GhosttyService.snapshotDebounce`) and driven by
  the terminal's own output, with the app-wide job poll as a backstop. See
  `documentation/terminal.md` for why the hub cannot read the surface itself.
- **The end signal has one source.** The terminal is a PTY in this process, so
  `GhosttyService` reports its end and `PaneStreamHub.endViewers(ofSession:)`
  delivers the `ended` message. Both ways a terminal ends reach it: the child
  exiting, and the row being closed.

A grid that moves after a viewer attached reaches it through one entry point. A
viewer is told its size in the paint it receives on attach and by nothing else on
the socket, so `PaneStreamHub.noteSize` is what keeps that current:
`GhosttyService`'s resize handler calls it with the grid it just read from the
surface. The viewer receives a fresh `resize`
followed by a repaint of the reflowed screen, and a report that did not move the
grid is deduplicated rather than delivered.

## Controlling side: connecting to another instance

Any Wietty instance can add one or more other instances as remote
connections and drive them from its own sidebar, without opening a browser.

The controlling side lives in the [wietty-shared](https://github.com/kloostermanw/wietty-shared)
package, so the macOS app and the iPadOS client decode the same wire format with
the same code. This app keeps the entire served side, plus one adapter
(`RemoteProjectAdapter`) that maps the package's `RemoteWorkspace` values onto
the local `Project` type `WorkspaceCardView` expects.

### Setting up a connection

Settings has a "Remote connections" section, below "Remote access
(experimental)". It lists the connections already added
(`RemoteConnectionsStore`), each row showing the connection's name and
`host:port` with edit and delete buttons, and below the list a form to add a
new one (name, host, port, token). The token here is the same shared token
shown on the other Mac's "Remote access (experimental)" Settings section.
`RemoteConnectionsStore` splits persistence: name, host, and port are stored
in `UserDefaults`, while each connection's token goes to the Keychain via a
`SecretStore` (`KeychainSecretStore` in production, an in-memory stand-in in
tests), keyed by the connection's id, so tokens are never written to disk in
plaintext. Every add, edit, or delete immediately starts or stops the
matching `RemoteWorkspaceStore` (`RemoteWorkspacesController.sync()`); there
is no separate "connect" step.

There is no remote rename and no remote workspace removal. A connection can
only be added, edited (name, host, port, token), or removed; the workspaces
and sessions it exposes are managed on the other Mac, not from here.

### The grouped sidebar

The sidebar is grouped into collapsible sections: one "Local" section, and
one section per remote connection, each titled with the connection's name.
Every section starts with a `SidebarSectionHeaderView` (a title, a collapse
chevron, and trailing icon buttons); collapsing a section persists across
launches. The Local section's buttons refresh git status and add a project
folder. Each remote section's buttons reconnect the control socket
(`store.stop(); store.start()`) and remove that connection from Settings.

While a remote connection is not `.connected` (`.connecting`, `.unreachable`,
or `.unauthorized`), its section shows a short status line ("Connecting…",
"Unreachable. Retrying…", "Unauthorized: check the connection's token.")
instead of workspace cards. Once connected, its workspaces render with the
same `WorkspaceCardView` used for local projects, fed from the store's
snapshot through `RemoteProjectAdapter`. Remote sections do not support the
drag to reorder or drop zone that the Local section has.

Each remote section is its own view, `RemoteSectionView`, holding its
`RemoteWorkspaceStore` as an `@ObservedObject`. That is a requirement rather
than a preference: the store is a nested `ObservableObject` inside
`RemoteWorkspacesController`, and a view observing only the controller would
never redraw when a snapshot arrives, so the sidebar would silently stop
updating.

### Remote actions

A remote workspace card supports exactly the subset of actions that have a
server side endpoint: open a new terminal, open a new claude session, attach
to (tap) an existing session, restart a session, and close a session. Any
action without a remote equivalent (rename, remove a terminal, remove a
project, enable sync, apply config, process controls) is wired to a no-op on
remote cards; those controls render but do nothing. There is no way to
create, rename, or remove a remote workspace from the controlling instance.

Actions do not block the UI: `RemoteWorkspaceStore` sends the request and lets
the next pushed snapshot (see below) reconcile the UI, typically within a few
hundred milliseconds. A failure is not swallowed, though. If the request
returns a non success status or the host cannot be reached, the store records a
short message in `lastActionError` and the section shows it as a small red
caption, so a rejected open, restart, or close is visible rather than silent.

### Live state: the control channel

Each `RemoteWorkspaceStore` opens one `WS /control` connection to its
instance and keeps it open for as long as the connection exists in Settings.
On connect, the server pushes a full snapshot,
`{"type":"snapshot","workspaces":[...]}`, built by the same
`WorkspaceSerializer` used for `GET /api/workspaces`. From then on, the
server watches for workspace changes (`ProjectStore.workspaceChanges()`) and
pushes a fresh, full snapshot, debounced by 250 milliseconds, whenever
something changes; there is no polling and no incremental diff format, every
push is the complete workspace list. The client applies each snapshot
wholesale (`RemoteWorkspaceStore.apply(snapshotText:)`) and marks the
connection `.connected` on the first one it decodes.

If the socket drops, the store asks `GET /api/workspaces` why. A 401 there means
the token is wrong, so the connection is marked `.unauthorized` and stops
retrying, since a retry cannot succeed until the token is corrected in Settings.
Any other answer, including none at all, is treated as a transient drop: the
connection is marked `.unreachable` and retried after a short backoff.

The refused WebSocket upgrade itself cannot be used for this. Hummingbird answers
a `.dontUpgrade` with 405 Method Not Allowed, not 401, so a bad token and a
broken route look identical on the socket. The REST route is the only place a
real 401 appears.

### The control REST API

The server (`RemoteServer.swift`) exposes, all token gated:

- `GET /api/workspaces`: the full workspace list as JSON
  (`{"workspaces":[...]}`), the same shape pushed over `WS /control`.
- `POST /api/workspaces/{id}/terminal`: opens a new terminal in the workspace
  with that id.
- `POST /api/workspaces/{id}/claude`: opens a new claude session in the
  workspace with that id.
- `POST /api/sessions/{sid}/restart`: restarts the tracked session with that
  session id.
- `POST /api/sessions/{sid}/close`: closes the tracked session with that
  session id.
- `WS /control`: the push channel described above.
- `WS /attach`: the pre-existing live terminal stream (see "Served side"
  above), now also consumed by the native client, described next.

### Where an attached session is drawn

A tapped remote row is drawn in the main window's pane, by SwiftTerm rather than
the browser's xterm.js. The pane already draws the local terminals, so a remote
session lands beside the sidebar with no second window and no tab bar, and its
sidebar row is marked the same way a local one is. One terminal is on screen at a
time, local or remote, and `PaneSelection` is what decides which.

Only the session on screen holds a `WS /attach` connection: switching away discards
its view, which stops the socket, and coming back attaches again. That loses the
scrollback that viewer had accumulated and not the screen, because the server
paints the current grid on attach. A session that ends while it is on screen keeps
its last output with the `[session ended]` banner under it, matching what the pane
does for a local terminal whose command exited.

A session that rings the bell on a connected Mac also posts a notification here,
built by diffing the `needs_attention` flag across successive snapshots, since
the protocol has no bell message of its own. `documentation/bell-notifications.md`
covers that diff and the two rules that keep a reconnect from re-announcing every
waiting agent.

Either way, a connection removed while one of its terminals is still on screen
never reconnects it. The tabbed window leaves the tab showing a placeholder; the
pane goes back to the local terminal instead, because a remote row removed with
its connection leaves nothing in the sidebar to click out of a placeholder with.

## Ports

Two servers run on separate ports, both configurable in the "Ports" section
of Settings:

- MCP server: `127.0.0.1:7433` (loopback only).
- LAN remote terminal and control API: `0.0.0.0:7434` (reachable on the local
  network).

Ports are clamped to the range 1024 to 65535 and persisted. Changing a port
restarts the affected server.

## Security

The security posture is deliberately minimal, for a trusted home or office
wifi, on both the served and controlling side:

- Opt in, off by default.
- A shared token is required on every HTTP request and on every WebSocket
  handshake (`/attach` and `/control`), whether the caller is a browser or
  another Wietty instance. A missing or wrong token is rejected. The
  token is generated on first use and persisted; a remote connection stores
  its own copy of the target instance's token.
- Traffic is plain HTTP and WebSocket on the LAN. It is not encrypted, for
  either the browser client or instance to instance control traffic.

Accepted risk: on a shared or hostile network, screen contents, keystrokes,
and workspace state travel unencrypted, and the token can be observed by an
on path attacker. Use these features only on networks you trust; the
Settings UI states this. TLS and internet (WAN) access are future work, as
are Bonjour discovery, scrollback, and remote resize. An iPadOS client is in
development.
