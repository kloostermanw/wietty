# The terminal

A terminal or Claude session is a pseudo-terminal Wietty spawned and owns, rendered by a
libghostty surface in the pane of the app's own window. Nothing has to be installed for it: not
iTerm2, not tmux, not even Ghostty.app. `docs/remote-access.md` covers how a terminal's
bytes reach a browser or another Mac.

**Terminals do not survive quitting Wietty.** A PTY is this process's child, so it dies with the
process, and every session id the app minted is therefore wiped at launch by
`ProjectStore.clearDeadSessions()`. The rows survive and can be reopened; only the ids go. That wipe
is deliberately not reported to the user: nothing is lost that they did not choose by quitting, it
happens on every launch, and a notice each time would be noise.

**The wipe takes only `gt:` ids.** A workspace stored by an older version can still hold rows whose
ids iTerm2 or a tmux server minted. Those are left exactly as they are, because they cost nothing:
`ProjectStore.activate` asks the service to focus one, is told it is gone, and opens a real terminal
in its place. Stored `Project.windowId` values are left alone for the same reason. Nothing reads
them.

## What the app is built from

| Piece | What it is |
| --- | --- |
| `TerminalService` | `GhosttyService` |
| `ScreenStreaming` | `PaneStreamHub` |
| `SessionMonitoring` | `GhosttyMonitor` |
| `TerminalStack.ghostty` | the `GhosttyStack` |

`TerminalStack` builds the surface host, hands its failure to `GhosttyStack` as a `TerminalError`,
and passes the three protocol shaped pieces on. The protocols stay because they are test seams: a
fake service, a fake hub and a `FakeSurfaceHost` are how most of this is exercised without a Metal
device. `UnavailableTerminalService` is what every terminal action reaches when libghostty or the
bundled helper could not start, so the failure is one actionable message rather than a crash at each
call site.

The pane in the main window (`RightTerminalView`, drawn in
`docs/AsciiScreens/ContentView.md`) is not only for local terminals: a remote session tapped
in the sidebar is shown in the same pane, by SwiftTerm rather than libghostty, and
so is a process's log.

## What a terminal is

Three objects that are created together and die together, plus one process outside the app:

| Part | File | What it is |
| --- | --- | --- |
| The pty | `Wietty/RawPTY.swift` | The master fd, the child's process group, and one raw byte stream off the master. |
| The tee | `Wietty/TerminalRelay.swift` | A unix socket listener that copies bytes between the pty and the surface, and hands every read to the stream hub as well. |
| The surface | `Wietty/GhosttySurfaceHost.swift` | The one `ghostty_app_t`, one `ghostty_surface_t` per terminal, and the `NSView` each renders into. |
| The helper | `wietty-pty/main.swift` | A separate executable in the app bundle, run as the surface's command. It connects to the relay's socket and copies bytes. |

`GhosttyService` (`Wietty/GhosttyService.swift`) keeps the three in step and is the only type that
knows a terminal is not a single object. It mints the session id itself, as `gt:<uuid>`, because there
is nothing to ask for one: the PTY belongs to the app.

**The surface's `NSView` lives for the terminal's whole life, and it cannot be otherwise.**
`ghostty_surface_new` takes the view in its config (the macOS platform union is `{ void *nsview; }`),
so a surface without a view does not exist. The pane therefore re-parents an existing view rather
than creating a surface when a row is selected: a live surface survives being removed from its
superview and added into a different `NSWindow` with its child still running and its scrollback
intact, and recreating it is what would lose that scrollback. Every design decision in
`LocalTerminalView` and `SurfaceContainer` follows from this, in particular that
`dismantleNSView` frees nothing.

## Why there is a helper process

**libghostty spawns and owns its own child, and exposes neither a byte feed nor an output callback on
the backend this app uses.** `ghostty_surface_config_s` carries a `command`, a `working_directory` and
an environment, and on `GHOSTTY_SURFACE_IO_BACKEND_EXEC` there is no way to hand bytes in or to be
handed bytes out. A terminal built on that alone would leave Wietty owning no byte stream, and with
no byte stream there is nothing to serve a remote viewer with and nothing to read a terminal's output
from.

So Wietty owns the pty and the surface runs the helper. The surface's command is
`wietty-pty <socket-path>`, never the user's shell. That is the entire reason `wietty-pty` is a
second target in `project.yml` and is copied into `Contents/MacOS` of the app bundle. A build where
the copy phase did not run has no helper, which `GhosttyStack` reports as a startup error rather than
failing per terminal, because every surface's command would be missing.

The helper interprets nothing. Ghostty's VT is the only VT in the path and the pty Wietty owns is
the only line discipline, so anything the helper did to the stream would be wrong twice. It does put
its own tty into raw mode, because otherwise that outer line discipline echoes every keystroke a
second time and translates carriage returns before the shell sees them. Its exit statuses are
meaningful, since the surface displays them: 64 for usage, 69 for a socket nobody is listening on
(the terminal is already gone), 70 for a socket that could not be created.

## The byte path

**Output**, in order, all of it on one serial read source per terminal:

1. `RawPTY.startReading` reads the master.
2. `TerminalRelay` hands the chunk to `onOutput` first and unconditionally, which is
   `PaneStreamHub.write`, so a remote viewer's bytes never wait behind the local surface.
3. The same chunk is written to the helper's socket, and the helper copies it to its stdout, which is
   the pty libghostty renders.

**Input** converges on the pty master, whatever its source:

- A key typed into the pane goes to `ghostty_surface_key`, libghostty writes it to the helper's tty,
  the helper copies it to the socket, and the relay writes it to the master.
- A keystroke from a remote viewer arrives on `PaneStreamHub.onSend`, is yielded into an
  `AsyncStream` with a single consumer, and reaches `GhosttyService.send`, which writes the master.
- MCP and the sidebar reach the same `send`.

**No write to the master happens on the caller's thread.** `RawPTY.write` hands the bytes to that pty's
own serial queue. A master write parks once the child stops reading and the queue fills, and
`GhosttyService.send` is main actor code reached from the remote keystroke stream, from MCP and from the
sidebar, so performing the write there froze the whole UI until the foreground program read its stdin,
which it need never do: measured at 5.17 s for a paste into a `sleep 5`. Local keystrokes were never
exposed to it, arriving on the relay's own queue, which is what made this look like a remote-only
problem rather than a property of the write.

Two details, if you go probing. The block needs a completed line and not merely a full queue, because
`ptcwrite` parks when the queue is full and either the canonical queue is non-empty or the tty is
non-canonical, so a paste of one enormous line into a canonical tty does not park at all. And the queue
has to be serial: input order is as load bearing as output order, so a concurrent queue would scramble a
paste that arrives as several chunks, which is the same thing the `AsyncStream` above protects upstream
of it.

**Where ordering is guaranteed, and why it is arranged that way.** Output order is the read source's:
one serial `DispatchSourceRead` per pty, with both destinations written from inside its handler, so
the hub and the surface see the same bytes in the same order. Terminal output delivered out of order
is corrupt on screen, and a caller that fanned these chunks onto unstructured `Task`s would corrupt
it, since two Tasks created in order can still run in either order. Input order is the pty master's,
which is why remote keystrokes go through a single-consumer `AsyncStream` rather than a `Task` per
keystroke: a paste arriving as several messages must not be reassembled scrambled. This is the same
rule `TmuxStack.onSend` follows with its serial queue.

Output produced before the helper connects is buffered, up to 1 MiB, oldest bytes dropped first. A
surface is created after the shell is spawned, so a prompt or a shell startup notice printed in that
window would otherwise never reach the local view even though remote viewers already have it. While
that backlog drains, new output keeps queueing behind it instead of taking the direct path and landing
ahead of it.

**Window size deliberately does not travel on the socket.** Wietty reads the surface's geometry
from libghostty directly and resizes its own pty, so the socket stays a plain byte pipe with no
framing and the helper needs no signal handling and no `SIGWINCH` story. See "Sizing" below.

## Sizing

libghostty is the sizing authority. `GhosttySurfaceView` sends the surface its content scale and then
its pixel size (in that order, because libghostty derives the grid from size divided by scale), reads
the grid back, and reports it through `TerminalSurfaceHosting.onResized`; `GhosttyService` applies it
to the pty with `TIOCSWINSZ`. Nothing else can change the grid: a remote viewer letterboxes, scrolls
or scales.

Two details are load bearing:

- **A terminal is spawned with a size, not resized into one.** `GhosttyService.initialSize` is 120 by
  34 and is applied to the pty as `forkpty` creates it. A full screen program lays itself out from the
  size it finds at startup, so a terminal opened at 80 by 24 and corrected a moment later draws for a
  grid that does not exist until something forces a redraw.
- **The first grid report is guaranteed to arrive after `createSurface` has returned**, one main queue
  turn later. `GhosttyService.open` registers the session in its dictionary only after that call, and
  its `onResized` handler resolves the session through that dictionary, so a report from inside
  `createSurface` would be dropped. Because reporting latches on the last grid, no later event would
  correct it, and the pty would stay at its spawn size for the terminal's whole life. The failure is
  silent, which is why the guarantee is part of the protocol rather than a caller's responsibility.

A surface that is not in the view hierarchy is not laid out, so it keeps the grid it had until it is
selected again. Two terminals in one window can therefore have different sizes, and the one on screen
is always the one that matches the pane.

## Drawing

Redraw only when libghostty asks, coalesced onto one main queue turn. Measured idle CPU over five
seconds with a live shell and no output: draw on demand 0.06 s, a 60 Hz `DispatchSourceTimer` 0.48 s,
a display link 1.12 s. All three render correctly; the clocks just burn that per pane, and a workspace
can hold eight. `ghostty_app_tick` runs only in response to `wakeup_cb`, on the main thread, and every
other call in this API is main thread only.

The view supplies no layer of its own. libghostty replaces `view.layer` with its own `IOSurfaceLayer`
on the first frame, so a host-supplied `CAMetalLayer` survives only as a detached object and every
metric written to it is silently invisible. Write to `view.layer`, never to a cached layer.

**The user's own Ghostty configuration is loaded, deliberately** (`ghostty_config_load_default_files`).
The font, theme, and cursor they already chose for Ghostty are the right defaults for a Ghostty terminal
inside another app. It also means their keybindings are live, which is why `onCloseRequested` has to
handle a `close_surface` binding as well as a command exiting: that binding has no other way in.
`ghostty_init` is called with argc 0 on purpose, and `ghostty_cli_try_action` must never be called;
either would make this process behave like the `ghostty` CLI rather than like Wietty.

**Wietty's own overlay is loaded after it** (`~/.config/wietty/ghostty.cfg`, `GhosttyOverrideFile`), so a
setting Wietty offers in its Settings window wins over the user's own config for Wietty's terminals while
Ghostty.app is untouched. Two things ride on this overlay: `desktop-notifications` (see notifications.md)
and the terminal's colours (`background`, `foreground`, `cursor-color`, `cursor-text`,
`selection-background`, `selection-foreground`), which the General tab's "Ghostty colors" section writes
through `GhosttyColorSettings`. A colour left unset writes no line, so the user's own theme decides it;
a colour set here overrides that theme. Every write is followed by a reload, so a colour reaches terminals
already open (see `reloadConfig`).

## What the terminal asks of the store

Almost nothing. There is no workspace object anywhere to name, because the PTY belongs to the app
rather than to a server, so there is nothing to derive, nothing to bring up before an open, and
nothing that can belong to something else. Two things are worth stating:

- **The job name is polled.** libghostty pushes the title and the bell through its action callback but
  reports nothing about a terminal's foreground command, so it has to be asked for. The poll is
  `JobPoll`, an app-wide check (see `docs/periodic-checks.md`), and it is cheap: one
  `tcgetpgrp` on the master plus one `proc_name` per live terminal, with no fork. `ProjectStore` is
  handed it as a closure, `GhosttyStack.pollJobs`, because the answer needs a live `GhosttyService`
  and the store is built before one exists.
- **The launch wipe is guarded against running twice in one process.** The guard is not optional:
  `store` is `@State` one level above the window that hosts `ContentView`, so closing and reopening
  the "Wietty" window recreates the view and re-fires its `.task` while the surfaces keep running
  underneath. A second run would read those live rows' real session ids as stale leftovers, wipe them,
  orphan their PTYs, and make running terminals look closed. It is a per process flag rather than a
  `UserDefaults` one, because the wipe must still run on every real relaunch.

`Project.windowId` is never read and never written: `GhosttyService.open` echoes back the id it was
handed rather than minting one.

`GhosttyService` also owns retiring a dead terminal itself rather than leaving it to whoever wired the
callback. The service's own dictionary is the source of truth, so a corpse left in it makes the census
report a dead terminal as attachable, polls a closed master, and leaks the relay's socket file. Note
the ordering that follows: the terminal is reaped before `onTerminated` fires, so a handler asking what
is live never sees the terminal it is being told about.

**Removing a row closes its terminal.** "Remove" reads as "forget this row, leave its terminal
alone", and there is nothing here for that to mean: a session id is recorded nowhere but on its row,
so the row is the handle, and dropping it silently left a live shell, its pty, its socket file, its
helper process and its surface running with nothing in the UI able to name any of them until the app
quit. `ProjectStore.releaseOrphaned` closes them instead, on the row removal and on the workspace
removal alike.

## What happens to a terminal that stopped

The entry survives its child, and everything that acts on a terminal therefore has to ask whether
there is still a terminal to act on. Three answers follow, and they are what make a stopped row behave
like the closed row it is:

- **`focus` answers not found.** `ProjectStore.activate` reopens whatever `focus` reports not found, so
  this is what lets the play button on a finished Claude row start it again. Answering `found: true`
  for a corpse left that button doing nothing at all: the row could not reopen, and `jobKnown` was
  false because the master was closed, so the store had nothing to act on either.
- **`send` throws.** The master is closed, so the bytes went nowhere and nothing said so. An MCP
  `send_input` and a remote keystroke both looked delivered.
- **`readOutput` keeps working**, which is the point of keeping the surface at all.

The reopen is what frees the surface, through `TerminalService.discard`. It is a protocol method with a
default that does nothing, and `ProjectStore.activate` calls it on the old id before opening the
replacement.
It deliberately does not happen in `focus`: `focus` is also the MCP select, and a query must not
destroy the screen it was asked about. The moment of revival is the one moment that screen is finished
with, and without the call a revived row cost a leaked surface and `NSView` for the life of the
process. A `discard` naming a live terminal does nothing, so a caller that reached it by mistake cannot
turn a click on a running row into a silent close.

## Where events come from

`GhosttyMonitor` is the app's single listener, and its three kinds of event have three different
sources, which is not arbitrary:

- **Titles and bells** come from libghostty's runtime action callback (`GHOSTTY_ACTION_SET_TITLE`,
  `GHOSTTY_ACTION_RING_BELL`), not from parsing the byte stream. The stream is available and
  `PaneStreamHub` counts bells in the byte stream for the viewers it serves, but libghostty has already parsed both correctly,
  and reading titles out of the stream would need OSC 0 and OSC 2 handling that `OSCStringTracker` does
  not do. The hub's bell hook is therefore left unwired here.
- **Terminations** come from `GhosttyService`, because a child exiting is what a termination means here
  and the service is what reaps it.
- **Job names** are polled, as above.

A title change and a close request can both arrive on libghostty's own thread, so both hop to the main
queue carrying the session id rather than the view: after the hop the surface may already be gone, and a
stale object pointer would be a use after free where a missing dictionary entry is simply nothing to do.
The runtime callbacks are C function pointers and cannot capture, so they reach the one host through a
weak static; a callback that has hopped must find nothing rather than resurrect a released host.

One subtlety in that C API is easy to get wrong and silent when you do: **the userdata of a surface
scoped runtime callback is the surface's own userdata, not the app's.** libghostty passes
`surface.userdata` to `close_surface_cb`, `read_clipboard_cb` and `confirm_read_clipboard_cb`, and the
app's userdata only to `wakeup_cb`.

## Serving a remote viewer

The producer is `TerminalRelay` writing into `PaneStreamHub.write`, so the bytes on the wire are the
child's own. `docs/remote-access.md` is the protocol reference. Two things are worth stating here.

**The first paint is monochrome and its cursor is approximate.** `ghostty_surface_read_text` is the
only read back libghostty offers and `ghostty_text_s` carries no attributes, so a snapshot is plain
text and nothing in it can be coloured. The C API has no cursor getter of any kind, so `ScreenSnapshot`
places the cursor at the end of the last non-empty row, which is right for a shell at a prompt and
wrong for a full screen program. Both costs last exactly one frame: every byte after the paint is the
terminal's own and is exact. The first paint is the weaker half, since
`capture-pane -e` carries attributes and `display-message` answers the real cursor position.

**The paint is built from the last recorded snapshot, not from the instant of attach.** The hub asks
for it on its own delivery queue and cannot hop to the main actor, where the surface can be read: the
census gates the attach and has to be answered before the viewer is registered, and the paint has to be
ordered against the flush carrying the bytes produced while it ran. `SharedTerminalState` is the
lock-guarded registry that makes both questions answerable off the main actor.

That makes staleness a number, and the number is `GhosttyService.snapshotDebounce`, **300 ms**. It is
driven by output, because output is the only thing that changes a screen: a chunk arriving on the
relay's queue marks the session dirty and schedules one refresh per window, so a terminal printing a
megabyte costs one read rather than one per chunk. A resize and a selection change record immediately,
since those are the moments a screen changes shape. The job poll is a backstop only, refreshing every
live terminal once per tick, which covers an idle terminal whose screen changed for some reason other
than its own output.

Two earlier versions of this got it wrong, and both are worth recording, because both look correct
until a viewer attaches to an idle terminal. Recording only on resize and selection meant a terminal opened and then attached to from a browser had had neither since
its surface was created, so the viewer was painted the empty screen from that moment: measured against
a running instance, the paint was `ESC[2J ESC[H` and a row count of zero. Bounding it on the job poll
instead was better and still wrong, because that poll's interval is 15 seconds while a workspace is
expanded and 300 when everything is collapsed, so a viewer could be shown a five minute old screen and
only then start receiving live bytes, with everything in between missing. Neither figure is the answer
to "how stale can a first paint be"; 300 ms is, and it is a property of this type rather than of an
unrelated setting.

**A viewer is also told when the grid moves**, which takes wiring here rather than coming for free. A
viewer learns its size in the paint it receives on attach and from nothing else on the socket, so a
window resize would otherwise leave every already attached viewer rendering reflowed bytes against the
old grid until it reattached. The report comes from the
surface, so `GhosttyService`'s resize handler carries it into `PaneStreamHub.noteSize`, which is the
same code path. Two details are load bearing. The hub deduplicates on
the last size it saw, because libghostty reports a grid on events that need not have moved it (a font
metric change, a re-parent) without the grid having moved. And the
service records its snapshot *before* it reports the size, because the report is what makes the hub
repaint: reported first, that repaint would read the screen as it was before the reflow and then be
contradicted by the bytes the reflow produced.

The direction of that hook matters as much as its order. It runs on the main actor and hands the size to
a lock-guarded hub; nothing on a hub queue reaches back into the main-actor-isolated service, which is
the same rule the census and the paint follow through `SharedTerminalState`.

**A viewer is told when the terminal ends**, and that also takes wiring here. The census answers an
attach that has not happened yet; a browser or an iPad already watching a session has nothing else to
learn from, and there is no `%window-close` to arrive either, because the terminal is a PTY in this
process. So `GhosttyService` reports a stream that is over through its own hook, which
`GhosttyStack` wires to `PaneStreamHub.endViewers(ofSession:)`, the method the hub exposes
from `%window-close` and from a session the server no longer holds. Both ways a terminal ends are
reported: the child exiting, and the row being closed. Without it a viewer went silent forever, which is
indistinguishable from an idle terminal and is exactly the state the census exists to prevent for a
viewer arriving later.

The snapshot the hub paints from is not monotonic and the hub does not assume it is. A host that
answers nil, which it does for a surface with no grid yet, overwrites a good screen with nothing, and
the hub reads an empty paint as a capture that failed rather than as an empty screen: the viewer keeps
whatever it had and the live bytes bring it current. Keeping the older screen there would mean painting
a state the terminal has since left.

The recorded screen that `readOutput` answers from is held to a stricter rule, because it has no live
bytes behind it to bring a viewer current: `recordSnapshot` never replaces a recorded non-empty screen
with the blank a surface reads the instant it leaves the screen (see "Reading a terminal's output"). A
live screen always has at least its prompt row, so an empty read is the off-screen case rather than a
cleared screen. Clearing a recorded screen is left to `close` and `discard` (via `tearDown`) and to
`closeAll`, which record nil directly. `reap` deliberately keeps the screen so a terminal stays readable
after its child exits.

## Reading a terminal's output

`GhosttyService.readOutput` answers an MCP read of what a terminal has printed, and **scrollback is
reachable.** This was recorded as a limitation for a while and it is not one.

`ghostty_surface_read_text` takes a selection, and each of a selection's points carries a coordinate
mode as well as coordinates. **The coordinate mode decides the span, not the point tag.**
`GHOSTTY_POINT_COORD_EXACT` addresses a row, while `TOP_LEFT` and `BOTTOM_RIGHT` mean "the extreme of
this space" and ignore x and y. So a `GHOSTTY_POINT_SCREEN` selection from `TOP_LEFT` to
`BOTTOM_RIGHT` is the whole screen, scrollback included, and no height getter is needed to ask for it.
`EXACT` cannot substitute: measured against a 50,000 line scrollback in a 28 row grid, `SCREEN` with
an `EXACT` y as far as 9999 returned 28 rows, so it clamps to the grid and cannot address history at
all.

**The cost is what shapes the rest.** On that same scrollback, on the main actor, the viewport read
measures 0.14 ms and the whole screen read 29 ms, plus roughly 5 ms to decode and split it. So
`GhosttySurfaceHost.snapshot` picks the viewport read whenever the caller asks for no more rows than
the grid holds, the boundary included, and `GhosttyService.recordSnapshot` always asks for exactly the
grid's own row count rather than a fixed larger number. `readOutput` honours the caller's `maxLines`
instead, because reaching history is the whole point of that call and it runs once per request rather
than once per notch of a window drag.

**A read of a surface that is not on screen falls back to the recorded screen.** `read_text` answers
nothing for a surface that is not the displayed pane, and in a one window, one terminal app that is
every MCP read except the one session the window happens to be showing, so a live read alone returned
an empty string for exactly the reads `get_process_output` exists to serve. So `readOutput` tries the
live surface first, the only path that reaches scrollback, and when it comes back empty it answers from
the screen `recordSnapshot` last recorded from the terminal's own output within `snapshotDebounce`. The
fallback is the viewport rather than the scrollback, since the recorded screen is the grid's own height,
but it is what the terminal printed rather than nothing. It works only because recording is kept honest
for it: an off-screen surface reads blank, and `recordSnapshot` refuses to record that blank over a
screen it already has, so output arriving the instant a pane leaves the screen cannot erase what the
next read falls back to.

**The boundary is the case that runs, so it has its own function**,
`GhosttySurfaceHost.readsScrollback(maxLines:gridRows:)`, and a test at 27, 28 and 29 rows against a 28
row grid. It was `>=` once, which sent `recordSnapshot` (a resize away, and every 300 ms while output
flows) down the whole screen path: roughly 34 ms of main actor time per live terminal per refresh
instead of 0.14 ms, so eight terminals with deep scrollback stalled the app for about a quarter of a
second every 300 ms while anything printed. Nothing failed and nothing logged, and the whole suite
passed, because `FakeSurfaceHost` answers both spans the same way. Only a comment claiming the saving
gave it away.

## Spawning the shell

`RawPTY.spawn` uses `forkpty`, and that is not a style choice. Four findings sit behind that file, and
every one of them fails silently, which is what makes them expensive to rediscover.

**`posix_spawn` cannot give a child a controlling terminal.** `POSIX_SPAWN_SETSID` makes the child a
session leader, but acquiring the ctty needs `ioctl(TIOCSCTTY)` and there is no spawn file action for
an ioctl. The failure is silent and does not look like a spawn bug: the shell reports `tty = ??` and
`tpgid = 0`, cannot open `/dev/tty`, and has `monitor` off, so `^C` reaches nothing. The foreground
command keeps running while the session echoes keystrokes and executes none of them, which reads as a
hang. `forkpty` does the `setsid` and the `TIOCSCTTY` itself. `PTYProcessLauncher` may keep using
`posix_spawn`, because a logged managed process has no interactive job control to lose.

**`killpg` fails with ESRCH until the child's `setsid` lands.** `forkpty` performs it inside the child,
so between the parent returning from the fork and the child reaching that call the child is still in
Wietty's own process group and `killpg(pid, ...)` signals nobody. A `terminate()` issued straight
after `spawn` missed 5 times out of 5 with no delay and 0 times out of 5 with a 300 ms delay, leaving a
live login shell with no terminal, and that is exactly the shape of `GhosttyService.open`'s two failure
paths. `RawPTY.hangUp` therefore signals the group and the pid, the second being harmless afterwards
(the child has no descendants yet in that window, and later it is a second `SIGHUP` to a process
already being hung up). The hang up as a whole is skipped once the child has been collected, because
signalling a reaped pid aims at whatever the kernel handed that number to next, and on this substrate
that is the common case rather than an edge: `GhosttyService.reap` terminates a terminal precisely
because its child just exited.

**A child inherits the parent's signal mask and dispositions across both fork and exec.** So the child
resets every disposition to `SIG_DFL` and clears the mask before the exec, using only
async-signal-safe calls. This is measured, not defensive: the `xcodebuild test` host blocks `SIGHUP`,
`SIGINT` and `SIGQUIT`, and a shell inheriting that mask can be neither interrupted nor hung up, which
made `terminate()` a no-op under the test host. In production it would leak whatever signal state the
process that launched Wietty happened to leave behind into the user's shell.

**`proc_name` refuses a `MAXCOMLEN + 1` buffer.** It copies all 32 bytes of `proc_bsdinfo.pbi_name`,
so it needs `2 * MAXCOMLEN` plus a terminator; handed less it returns 0 with `ENOMEM` and no name for
any process on any machine, which reports every terminal's foreground job as unknown and silently
freezes every agent's status in the sidebar.

**The child is told what this terminal is, not what launched it.** `TERM` names what may be drawn
(above, and `RawPTY.terminalType`), `TERM_PROGRAM` and `TERM_PROGRAM_VERSION` name who is drawing it:
`Wietty` and the bundle's version. All three are set unconditionally, because the child's environment
starts as Wietty's own and every one of them would otherwise carry an answer about a different
terminal. `TERM_PROGRAM` is the variable a program reads to decide what its host supports (iTerm2
answers `iTerm.app`, Ghostty.app `ghostty`, Apple's Terminal `Apple_Terminal`), and leaving it unset
is not neutral. An agent choosing between the bell, `OSC 9` and `OSC 777` finds nothing to match and
emits none of them, so a terminal that handles all three (`docs/notifications.md`) never hears from
it, and the user sees no 🔔 and no banner. An app launched from the Finder inherits no value at all,
so the unset case is the ordinary one rather than the exception.

Everything the child needs is built before the fork, because between fork and exec only
async-signal-safe calls are legal: the child inherits one thread but every lock the parent held, so
touching the Swift runtime there can deadlock. That is why argv and the environment are already C
arrays and why the child block calls nothing but `signal`, `sigprocmask`, `chdir`, `execve` and
`_exit`.

`nil` from `foregroundJobName()` is an answer callers must respect rather than read as "no job".
`ProjectStore.activate` types `claude` into a Claude row whose agent it believes is idle, so a failed
query read as an absence submits that text into a live agent as a prompt. `jobEvents()` contributes
nothing for a terminal it could not query, and `FocusResult.jobKnown` encodes the same rule.

## What a Claude row is

A shell with `claude` typed into it, never a shell replaced by `claude`, and the
difference is two separate faults.

`RawPTY.spawn` runs a command as `zsh -l -c <command>`, which is a login shell but
not an interactive one, so it reads `.zprofile` and never `.zshrc`. A normal setup
puts its `PATH` additions in `.zshrc` (`~/.local/bin`, a version manager, a
language toolchain), so the command ran with a different `PATH` than the terminal
the user opens themselves. `claude` was not found, the child exited 127 within
milliseconds, the reap unlinked the relay socket, and the surface's helper, started
by libghostty a few milliseconds later, found nothing to connect to and printed
"Wietty: this terminal is gone" under a launch failure. Nothing in that pointed
at a `PATH`.

The second fault outlives the first. A command that exits takes its pty with it,
so the row became a dead surface: no prompt, nothing to type into, and no way to
recover it in place. A shell outlives its command, so a Claude row whose agent
exits falls back to a prompt and can be used or restarted.

`ProjectStore.openSessionThrowing` therefore opens every row with no command and
types the command in afterwards. That is also what `ProjectStore.activate` already
did to revive a stopped agent, so both paths now mean the same thing by "a Claude
row". Typing ahead is safe: the pty's line discipline buffers the bytes until the
shell reaches its first read, exactly as typing into a slow terminal does.

## The socket, and what it costs

**`sockaddr_un.sun_path` is 104 bytes including the terminator**, and the per user temp directory
spends roughly half of it. That is why `TerminalRelay.socketPath` uses a fixed `ipx-` prefix and only
12 hex digits of the session id, and why an owner pid cannot be encoded in the name even though it
would make the stale sweep precise. A path that does not fit fails loudly rather than binding a
truncated one, which would leave the helper connecting to a socket nobody listens on.

Because the name cannot say whose socket it is, `GhosttyStack.clearStaleSockets` uses age instead, and
`GhosttyStack.staleSocketAge` (one hour) is the single definition of "abandoned" in the codebase. It
is far longer than the milliseconds between a relay binding and its helper connecting, and far shorter
than the lifetime of the crashed run whose leftovers it exists for. Without that predicate the sweep
cannot be called safely at all: it would unlink the sockets of a second Wietty running alongside
(a Debug build next to the installed app) and of a relay in this very process whose helper has not
connected yet. A file whose age cannot be read is left alone. Nothing is lost by sweeping late, since
`TerminalRelay` unlinks before it binds, so a leftover file never blocks a new terminal.

**Writing to a vanished peer raises `SIGPIPE`, whose default disposition kills the process.** Measured
as exit status 141 on a one byte write, and the peer vanishing is routine rather than exotic, since the
helper is a child of the surface and goes away whenever a terminal is closed. Darwin has no
`MSG_NOSIGNAL` and an accepted socket does not inherit the option from its listener, so the relay sets
`SO_NOSIGPIPE` per connection; the write then fails with `EPIPE`, which the writer already reads as
"the helper is gone". The helper cannot use the same option, because its other write target is its own
stdout rather than a socket, so it ignores `SIGPIPE` process wide instead.

Descriptor lifetime is the other hazard on this path, and it is not a theoretical one: descriptors are
recycled, so closing one out from under an in-flight syscall does not fail, it writes a screenful of
terminal output into whatever the process opened next. Both `RawPTY` and `TerminalRelay` therefore
close a watched descriptor only in its `DispatchSource` cancel handler, and reference count the uses
that can overlap a cancel so the last one out performs a deferred close. The rules are written out at
the top of `TerminalRelay` and around `RawPTY.withMaster`; read them before touching either.

## Failing to start, and reporting it

`GhosttyStack` always constructs, exactly as `TmuxStack` does. Two things can be missing (libghostty
would not initialise, or the bundled helper is absent), and both are reported through `setupError`
rather than thrown, so the app launches and can explain itself instead of failing at every call site.
`ContentView` surfaces that error on launch rather than waiting for the first click, and
`LocalTerminalView` shows it in place of a terminal.

The reason is passed into the stack rather than patched on afterwards, so one error both reaches
`setupError` and is thrown by every terminal action through `UnavailableTerminalService`. Signalling a
libghostty failure by handing the stack `helperPath: nil` would report that libghostty could not start
while every terminal action threw "the helper is missing from the app bundle. Reinstall Wietty.",
and two different wrong answers to one question is worse than either. When both are wrong, libghostty
is reported, because it is the more fundamental failure and a build with that problem usually has the
helper problem too.

A stack that failed to build still answers the hub's session census, with an empty set rather than
leaving the hook nil. The distinction matters: `.unknown` means the query failed and must not end a
viewer, while an empty answer here is not a failed query but the truth. Without it an attach upgrades
a socket that then stays silent forever.

## Limitations, each with its cause

- **Terminals do not survive quitting Wietty.** The PTYs are this process's children. Every
  terminal is torn down explicitly on `NSApplication.willTerminateNotification`, synchronously, since
  an object still alive at exit gets no `deinit` and the relay's socket file would otherwise sit in the
  temp directory until the stale sweep reached it.
- **A remote viewer's first paint is monochrome, its cursor is approximate, and it is up to 300 ms
  stale.** Causes above, under "Serving a remote viewer".
- **The stream carries whatever `RawPTY.terminalType` resolved**, which is `xterm-ghostty` only when
  that terminfo entry is installed, and in practice that means Ghostty.app is present. Otherwise it is
  `xterm-256color`. Since needing no other terminal installed is this substrate's whole point, the
  fallback is the common case. Either way a remote client may receive sequences it does not implement,
  because the bytes are the child's own; see `docs/remote-access.md`.
- **The workspace badge setting does nothing here.** libghostty has no title setter of any kind, so the
  badge travels as the surface's initial title and reaches only the host's own record and the view's
  accessibility label. It is still passed rather than dropped, so that the day the C API grows a setter
  the value is already there.
- **libghostty can never render a remote session.** There is no way to feed bytes into a surface, which
  is the same fact that forces the helper. `RemoteTerminalView` therefore stays on SwiftTerm, and the
  local pane and the remote terminal window do not look alike.
- **An exited shell leaves a notice in the pane.** libghostty draws "Process exited. Press any key to
  close the terminal." and its close request only arrives with that next key. Wietty does not set
  `ghostty_surface_config_s.wait_after_command`, so this is `ghostty_surface_config_new`'s default
  rather than a choice made here. It costs nothing: the row's own state comes from the relay reaching
  EOF, through `GhosttyService.reap`, which is the one path that knows whether the shell exited.
  `GHOSTTY_ACTION_SHOW_CHILD_EXITED` is deliberately left unhandled for the same reason, and answered
  false so libghostty knows nothing was shown. On this substrate the surface's command is the helper,
  which ends because the terminal ended rather than the other way round, and a second notice drawn over
  the last screen would cover the thing worth reading.
- **The surface is kept after the child exits**, on purpose, so that last screen stays readable.
  `close`, `discard` and `closeAll` are the only things that destroy a surface, which is to say: closing
  the row, reopening it, or quitting. See "What happens to a terminal that stopped".
- **Dropping files onto the pane inserts their paths.** `GhosttySurfaceView` registers for `.fileURL`
  drags, so a file dragged from Finder inserts its path at the cursor, shell quoted, several files
  separated by a single space and with no trailing newline, which is how a path is handed to a CLI
  running in the terminal. Each path is single quoted with embedded single quotes escaped, so spaces,
  quotes and newlines in a filename cannot run as shell input. The text goes through `sendText`
  (`ghostty_surface_text`), the same plain path dictation and a Services item use, not the paste
  binding: one line with no newline needs no bracketed paste and would only raise the unsafe paste
  alert. Local pane only. The browser client and the iPad have the same gap and are served elsewhere.

Consciously deferred, so do not read the above as a complete feature list and do not promise these:
mouse shape (`GHOSTTY_ACTION_MOUSE_SHAPE` is unhandled, so a full screen program that asks for an
arrow gets an I-beam), mouse pressure and captured mouse mode, a general Command
`performKeyEquivalent` passthrough (only control plus return and control plus slash are intercepted,
because this window is a workspace manager first and its menu items are not the terminal's to
swallow), telling left and right modifiers apart, reclaiming the allocation behind a paste request the
user cancelled (the C API has no cancel entry point), and `acceptsFirstMouse`.

## The dependency

`GhosttyKit` comes from `Lakr233/libghostty-spm`, **pinned exactly** (`exactVersion: "1.3.2"`, never a
range) because the libghostty embedding API is explicitly unstable. `GhosttySurfaceHost.swift` is the
only file in Wietty that imports it, and nothing above `TerminalSurfaceHosting` may, so a breaking
release lands in one file and every test in this substrate runs against `FakeSurfaceHost` with no
framework and no Metal device.

Three things about that package are worth knowing before changing anything here:

- **It is a patched fork, not upstream.** Upstream Ghostty publishes no SPM product. The wrapper builds
  from a pinned upstream commit (`Ghostty.ref`) and applies its own patch set, which among other things
  patches `src/renderer/Metal.zig` and strips the inspector and custom shaders. It pins an upstream
  commit rather than an upstream release, so the version numbers on the pin are the wrapper's own and
  are not Ghostty's.
- **A host-managed IO backend exists in that package and is deliberately unused.**
  `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, with its `receive_buffer` and `receive_resize` callbacks,
  would remove the helper and the socket entirely. It comes from the wrapper's own
  `Patches/ghostty/0002-host-managed-io-modern.patch`, which creates `src/termio/HostManaged.zig`, so
  it is not in the upstream commit this pin builds from. Whether some later upstream release carries an
  equivalent is a separate question and worth re-checking when the pin moves; what is established is
  that this backend, in this pin, is the fork's. Building the byte path on it would tie the substrate
  to a single fork's out-of-tree patch, so `createSurface` leaves the backend at the default `exec` and
  the byte path depends on upstream API surface alone. Expect to find that backend and wonder why it is
  unused; this is why.
- **It is not behind a build configuration, on purpose.** The substrate is a runtime setting read at
  launch, so a shipped build has to contain libghostty whichever substrate a user picked. Gating it
  cannot make the shipped app smaller, it can only produce a second product that silently lacks a
  documented feature, and it would stop the default build from compiling the one adapter onto an
  unstable pinned C API, which is the last thing that should be allowed to drift uncompiled. The cost
  is real and is accepted: a 52 MB release asset, about 127 MB unpacked in `SourcePackages`, and a 39 MB
  static macOS slice linked even for users of the other two substrates.

**When a Ghostty release breaks the build**, the change belongs in `GhosttySurfaceHost.swift` and the
pin in `project.yml` moves as one commit. Check the header of the version you are moving to for the
facts this substrate rests on before assuming they still hold: that a surface is created with an
`NSView` and cannot exist without one, that `ghostty_surface_read_text` is the only read back and
carries no attributes, that there is no cursor getter and no title setter, and that the `exec` backend
offers no byte feed. `GhosttySurfaceHost.libraryVersion()` logs the linked library's own version at
startup; because the pin is exact, a mismatch between that and `project.yml` means a stale resolved
package rather than a version range.

A first resolve of this package can park indefinitely on a keychain prompt, with near zero CPU and an
empty artifacts directory. It is not the "cannot lock ref" failure and clearing caches does not help.
`CLAUDE.md` carries the workaround under "A first build can hang on package resolution".
