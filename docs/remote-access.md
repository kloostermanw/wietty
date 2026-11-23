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

1. Open the settings panel (the gear in the bar above the pane, or ⌘,) and turn on
   "Enable LAN remote terminal" in the "Remote access (experimental)" section.
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
libghostty renders; see `docs/terminal.md`. `WS /control` and the REST routes kept
their shapes across the substrates this app used to ship. `WS /attach` did not: it
speaks version 2 of the terminal stream protocol, described below, and a client
that does not ask for it is told to update. A session id on the wire is whatever
the serving Mac calls a terminal, and is opaque to every client.

The path from the browser back to the terminal, in order:

- **Browser (xterm.js).** `remote_index.html` bundles xterm.js. It fetches
  `GET /api/sessions` for the session list, then opens `WS /attach` with
  `protocol=2&resize=repaint` and `binaryType = "arraybuffer"`. Each message is
  applied in arrival order with nothing asynchronous in between, so the `resize`
  reaches the terminal before the `snapshot` is written. Binary frames are written
  without their type byte, unknown messages are ignored, `ended` and `error` stop
  the page without reconnecting (`error` shows its message in red), and input goes
  out as binary `data` frames of at most 64 KiB of payload. The page sends no
  `resize` and has no fit addon: the terminal stays at the grid the server says.
- **`RemoteServer.swift`.** A Hummingbird HTTP plus WebSocket server bound to
  `0.0.0.0` on the remote port (7434 by default), separate from the loopback
  MCP server. It serves the web client, the token gated session and workspace
  listings, the token gated per session socket, and the control socket
  described below.
- **`ScreenStreaming`.** The protocol `RemoteServer` is built against. It
  declares only `attach`, `detach`, `send`, `resync`, and `stop`, so the server
  does not know what is behind it, which is what lets a test back the server
  with a fake. It speaks `StreamMessage` from `wietty-shared`, which the route
  frames with `StreamCodec`.
- **`AttachedViewer` and `ViewerQueue`.** Between the hub and one socket: the
  viewer's bounded queue, its registration with the streamer, and the rate
  limited resync that answers an overflow. See "The terminal stream (protocol
  version 2)" below.
- **`PaneStreamHub.swift`.** The one producer. A session id on the wire is a `gt:`
  id the app minted. `TerminalRelay` writes every chunk of the child's own output
  into the hub, which coalesces on an 8 ms timer (a shell echoing a typed line
  emits one notification per character) and fans it out to every viewer of that
  session: the browser and the iPad consume the same bytes, so a rendering fault in
  either is fixed once. The app's own pane is not among them. It reads the surface
  libghostty draws into directly, and `RemoteServer` is the only caller of
  `PaneStreamHub.attach`; phase 3 of issue #84 is what puts the local pane on this
  route too. The bytes are delivered exactly as they were read, with nothing
  decoded or held back; a multibyte character straddling two flushes arrives in
  two messages and the viewer's terminal joins it. A write into a quiet session
  is delivered at once rather than on the next tick. A viewer that attaches is
  sent the grid and a snapshot first, from the terminal's screen model: the
  history and the screen behind a full reset, because a session sitting idle
  emits no output and would otherwise show a blank screen. The hub also feeds
  that model, in the same step that accepts a chunk for delivery, which is what
  lets the snapshot and the stream after it meet at exactly one byte.
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
the iPad, and the pane of another Mac showing this session. The serving Mac's own
pane is not a client of this route: it shows the libghostty surface, and only
phase 3 of issue #84 puts it on the stream. Remote keystrokes take the same path
a local one takes, into the pty master, so both orders are the pty's: the hub
hands them to the pty's writer on the thread they arrived on, without the main
actor. Four things are worth knowing on the client side:

- **`TERM` is `xterm-ghostty` in the ordinary case, and `xterm-256color` only
  on a build that did not produce the bundled terminfo entry**
  (`RawPTY.terminalType`, which reads `BundledTerminfo`). The app compiles
  that entry into its own bundle and points the child at it with
  `TERMINFO_DIRS`, so Ghostty.app does not have to be installed on the serving
  Mac, and nothing is looked up with `infocmp`. See terminal.md, "Spawning the
  shell". Because the served bytes are the child's own, a program
  drawing for `xterm-ghostty` can emit sequences a client does not implement:
  xterm.js in the browser page and SwiftTerm in the iPadOS client each render
  what they support and ignore the rest. Nothing translates between them.
- **The snapshot on attach is coloured and exact.** A `resize` with the grid,
  then a `snapshot`: a full reset (`ESC c`) and the screen model's history and
  screen, every cell with its colours and attributes, the modes a program has
  set, the scrolling region, the tab stops, and the cursor where the terminal
  has it. It does not carry the palette, or the screen underneath an alternate
  screen; a viewer that attached on the alternate screen is sent a fresh
  snapshot when the program leaves it. A client keeps its own theme for indexed
  colours.
- **The snapshot is taken at the instant of attach and the stream continues
  from that byte.** The server takes what it has buffered, takes the snapshot,
  and registers the viewer as one step that no output can interleave with, so
  a viewer attaching while a build log scrolls sees no line twice and misses
  none. A multibyte character cut by that instant arrives whole. An escape
  sequence cut by it does not, and shows as stray characters until the next
  redraw. A viewer that has lost its place can be given the same join again
  (`resync`). See `docs/terminal.md` for the mechanism.
- **The end signal has one source.** The terminal is a PTY in this process, so
  `GhosttyService` reports its end and `PaneStreamHub.endViewers(ofSession:)`
  delivers the `ended` message. Both ways a terminal ends reach it: the child
  exiting, and the row being closed.

A grid that moves after a viewer attached reaches it through one entry point. A
viewer is told its size on attach and by nothing else on the socket, so
`PaneStreamHub.noteSize` is what keeps that current: `GhosttyService`'s resize
handler calls it with the grid it just read from the surface. Every viewer
receives a fresh `resize`; one that attached asking for repaints also receives a
`repaint` of the reflowed screen, and one that reflows by itself nothing more. The
attach route asks for what the query says (`resize=repaint` or `resize=reflow`),
and for repaints when it says neither. A report that did not move the grid is
deduplicated rather than delivered.

### The terminal stream (protocol version 2)

This is the reference for `WS /attach` in all three repositories. The messages and
their codec are defined once, in `wietty-shared` (`StreamMessage`, `StreamCodec`,
`StreamProtocol`); the route is `RemoteServer`, and `TerminalStreamConnection` in
the package is the client the Mac and the iPad use. The protocol version is the
integer 2 (`StreamProtocol.version`).

**Connecting.** The version and the resize mode travel in the query:

```
WS /attach?session=<id>&token=<t>&protocol=2&resize=repaint
```

- `token` is checked at the upgrade, as on every route. A wrong or missing one is
  not upgraded (Hummingbird answers 405, see "Live state" below).
- `protocol` missing: the client is an old one, recognised at the upgrade with no
  timer. The upgrade succeeds, and the server sends exactly two version 1 text
  frames and closes: `{"type":"data","vt":"<text>"}`, whose text is a red line
  (between a CR LF before and after) reading "This app is too old for this Mac.
  Update Wietty on this device.", then `{"type":"ended"}`. A version 1 client
  shows the line and the session as ended. These two frames, built by hand in the
  route, are the only version 1 code left. Nothing is attached.
- `protocol` present and not `2`: one `error` with code `protocol`, then the
  server closes. Nothing is attached.
- `session` missing: the server closes without sending anything.
- `resize` is `repaint` or `reflow` (see "Snapshot and repaint" below); missing or
  unknown means `repaint`.

**Messages.**

| direction | message | frame | fields | meaning |
|---|---|---|---|---|
| server to viewer | `hello` | JSON | `protocol` | accepted; always the first frame |
| server to viewer | `error` | JSON | `code`, `message` | refused; the server closes after it |
| server to viewer | `resize` | JSON | `cols`, `rows`, `own` | the grid in force; `own` is always false in this version of the server |
| server to viewer | `snapshot` | binary | VT bytes | a full reset (`ESC c`), then history and screen |
| server to viewer | `repaint` | binary | VT bytes | the visible screen again, history untouched |
| server to viewer | `data` | binary | raw bytes | the child's output, byte exact |
| server to viewer | `ended` | JSON | none | the terminal has stopped; the server closes after it |
| viewer to server | `data` | binary | raw bytes | input, byte exact |
| viewer to server | `resize` | JSON | `cols`, `rows` | "I am active, this is my grid" |

**Frames.** A JSON message is a text frame holding one object with a `type`
(`hello`, `error`, `resize`, `ended`) and the fields above, for example
`{"protocol":2,"type":"hello"}` or `{"cols":80,"own":false,"rows":24,"type":"resize"}`.
A JSON payload over 64 KiB is no message. A binary message is a binary frame whose
first byte is its type and whose remaining bytes are the payload: `0x02` `data`,
`0x03` `snapshot`, `0x04` `repaint`. (`0x01` is a JSON message, which on the
WebSocket travels as text; the codec reads it in a binary frame too.) A frame of a
type a side does not know is skipped, which is how a newer peer can say something
an older one does not need. The codec also defines a framing for a Unix socket
(four byte big endian length, type byte, payload); no route uses it yet.

**Order.** `hello`, then `resize` and `snapshot`, then live `data`. A session
that names no live terminal gets `hello` and `ended`. Every frame after the hello
is written by one writer per socket, in the order the hub delivered it.

**Sizes.** Outbound frames are written whole, whatever their size: a snapshot of
a full history is one binary frame of up to about 11 MB, and a client should
accept messages up to `StreamProtocol.maxMessageSize` (64 MiB).
`TerminalStreamConnection` does. Inbound, a frame and a message may each be up to
1 MiB (`RemoteServer.maxInboundMessage`); the WebSocket library's default of
16 KiB per frame used to close the socket on any paste larger than that. A
message larger than 1 MiB makes the server close the socket with 1009 (message
too big), so a client should send a larger paste as several `data` messages.

**The bound per viewer.** The server holds at most 4 MiB (`4 << 20` bytes) of
`data` and `repaint` payload for one WebSocket viewer, in that viewer's
`ViewerQueue`. A viewer that reads slower than the terminal writes overflows it:
everything queued for it except the control messages is dropped, and the server
resynchronises it with a fresh `resize` and `snapshot`, which replaces everything
the viewer holds. Until that snapshot comes, further output for that viewer is
dropped, and an `ended` waits behind it. When no snapshot can be built, the
viewer's stream carries on from where it is.

**The resync is rate limited**, at most one per viewer per 250 ms
(`ResyncThrottle`). Each resync formats the terminal's whole history on the hub's
one delivery queue, so a viewer overflowing again and again would otherwise stall
the viewers of every other terminal. An overflow sooner than 250 ms after the last
resync is answered when the 250 ms are over, as one resync however many overflows
came in between. A viewer that disconnects before then gets none.

**A viewer's `resize`** is accepted and not yet acted on: the server parses it
and ignores it, and answers nothing. Claiming the grid is the next part of
phase 3 of issue #84.

**Ending.** After `ended` or `error` the server closes the socket. When the
viewer closes, or its socket fails, the server detaches it from the hub.

## Controlling side: connecting to another instance

Any Wietty instance can add one or more other instances as remote
connections and drive them from its own sidebar, without opening a browser.

The controlling side lives in the [wietty-shared](https://github.com/kloostermanw/wietty-shared)
package, so the macOS app and the iPadOS client decode the same wire format with
the same code. This app keeps the entire served side, plus one adapter
(`RemoteProjectAdapter`) that maps the package's `RemoteWorkspace` values onto
the local `Project` type `WorkspaceCardView` expects. The served side consumes
the package too, for the message type of a terminal stream (`StreamMessage`),
so the core target links it as well as the app.

### Setting up a connection

The "Remote" tab of Settings has a "Remote connections" section, below "Remote
access (experimental)". It lists the connections already added
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

Each remote card's own collapse persists too, in the same `SectionCollapseState`
the section headers use, under a key built from both the connection id and the
workspace id (a workspace id is only unique on the Mac that owns it). A card
nobody has toggled starts collapsed, unlike a section header and unlike a local
card, so a connection serving a dozen workspaces does not push the Local section
off the top of the sidebar the moment it connects. The collapse is a preference
of the Mac doing the viewing and is never sent upstream: the serving Mac has its
own idea of which of its cards are open, and one viewer must not rearrange
another's sidebar. That is also why this needs no wire format change.

Each remote section is its own view, `RemoteSectionView`, holding its
`RemoteWorkspaceStore` as an `@ObservedObject`. That is a requirement rather
than a preference: the store is a nested `ObservableObject` inside
`RemoteWorkspacesController`, and a view observing only the controller would
never redraw when a snapshot arrives, so the sidebar would silently stop
updating.

### Remote actions

A remote workspace card supports exactly the subset of actions that have a
server side endpoint: open a new terminal, open a new claude session, tap a
session (which activates the row first, see below), restart a session, and
close a session. Any
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

Tapping a row is the exception: it waits for its reply. A tap first asks the
serving instance to activate the row (`RemoteWorkspaceStore.activate(refId:)`),
which opens a session when the row has none, and the pane attaches to the
session id that comes back rather than to the one the last snapshot carried. A
revived row gets a new session id, so a tap that used the id it already held
would attach to the session that just died and the pane would print
`[session ended]` with no way to get a working terminal out of that row. Waiting
for the reply also keeps a dead session off the screen entirely, instead of
showing one and swapping it a moment later. The request is capped at 15 seconds,
well below `URLSession`'s default, because a tap shows nothing until it answers.

The serving side of that is `ProjectStore.activateThrowing`, the same work a
click on a local row does, so a remote tap reopens a dead row and re-runs a
stopped agent's line exactly the way the Mac beside it does. It also focuses the
session in the serving Mac's own pane, which is the accepted price of having one
implementation of activation rather than two.

A tap that answers no session id is reported rather than dropped. Usually the
reason is already in the section's red caption, since a non success status
writes `lastActionError` like any other action. The case that leaves that empty
is a serving instance answering a success status with a body naming no session,
which no current version does and a mismatched or intercepted one can: the
controlling instance raises its own alert for it, because a click that quietly
does nothing is the failure this whole route exists to remove.

Note that a row's `run_state` cannot be used to decide any of this. It reports
the row's foreground job, not whether a session exists (for a plain terminal,
where the shell is the terminal, it answers "exited" only once the terminal
itself has ended), and it answers "running" whenever no job has been heard of,
which is the case for a row that was never opened and for every row of an
instance that has been relaunched.

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
- `POST /api/terminals/{ref_id}/activate`: gives the row with that id a live
  session, opening one when it has none, and answers with the row's terminal
  JSON. Keyed by the row's id rather than by a session id, unlike its two
  neighbours below, because the rows that need it are exactly the rows whose
  session id addresses nothing. `400` if `ref_id` is not a UUID, which no
  snapshot could have named. `404` if no row has that id, meaning the caller's
  snapshot is older than this instance's workspace list. `500` if the activation
  itself failed, or left the row with no session to attach to. The two `500`
  bodies carry the reason as `{"error": "..."}`, worded for a person and safe to
  show; a client that reads only the status is unaffected. The reason is also
  logged on the serving instance under the `remote` category.
- `POST /api/sessions/{sid}/restart`: restarts the tracked session with that
  session id.
- `POST /api/sessions/{sid}/close`: closes the tracked session with that
  session id.
- `WS /control`: the push channel described above.
- `WS /attach`: the live terminal stream, protocol version 2 (see "The
  terminal stream (protocol version 2)" above), also consumed by the native
  client, described next.

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
the protocol has no bell message of its own. `docs/notifications.md`
covers that diff and the two rules that keep a reconnect from re-announcing every
waiting agent.

Either way, a connection removed while one of its terminals is still on screen
never reconnects it. The tabbed window leaves the tab showing a placeholder; the
pane goes back to the local terminal instead, because a remote row removed with
its connection leaves nothing in the sidebar to click out of a placeholder with.

## Ports

Two servers run on separate ports, each configurable on its own tab of Settings
(the MCP port on "MCP", the remote terminal port on "Remote"):

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
