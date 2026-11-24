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
`ProjectStore.activate` asks the service to probe one, is told it is gone, and opens a real terminal
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
| The pty | `WiettyCore/RawPTY.swift` | The master fd, the child's process group, and one raw byte stream off the master. |
| The tee | `WiettyCore/TerminalRelay.swift` | A unix socket listener that copies bytes between the pty and the surface, and hands every read to the stream hub as well. |
| The surface | `Wietty/GhosttySurfaceHost.swift` | The one `ghostty_app_t`, one `ghostty_surface_t` per terminal, and the `NSView` each renders into. |
| The helper | `wietty-pty/main.swift` | A separate executable in the app bundle, run as the surface's command. It connects to the relay's socket and copies bytes. |

`GhosttyService` (`WiettyCore/GhosttyService.swift`) keeps the three in step and is the only type that
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
2. `TerminalRelay` hands the chunk to `onOutput` first and unconditionally. There `GhosttyService`
   feeds it to that terminal's `ProgramStatusTap`, which answers an `OSC 7501` support query on the
   spot (see "Program status" below), and then to `PaneStreamHub.write`, so a remote viewer's bytes
   never wait behind the local surface. Inside that call the hub also writes the chunk into the
   terminal's screen model (see "The server's own terminal" below), in the same step that accepts
   it for delivery.
3. The same chunk is written to the helper's socket, and the helper copies it to its stdout, which is
   the pty libghostty renders.

**Input** converges on the pty master, whatever its source:

- A key typed into the pane goes to `ghostty_surface_key`, libghostty writes it to the helper's tty,
  the helper copies it to the socket, and the relay writes it to the master.
- A keystroke from a remote viewer arrives as bytes on `PaneStreamHub.send(session:bytes:)`, and
  `onInput` hands them, on that same thread, to the writer `GhosttyService.open` registered for the
  session in `SharedTerminalState`: the pty's own `write`. The main actor is not on this path, so a
  busy UI does not hold remote input back. A terminal whose child has exited has no writer, and its
  input is logged and dropped.
- MCP and the sidebar reach `GhosttyService.send`, which writes the same master.

**No write to the master happens on the caller's thread.** `RawPTY.write` hands the bytes to that pty's
own serial queue. A master write parks once the child stops reading and the queue fills, and
`GhosttyService.send` is main actor code reached from MCP and from the sidebar (and was, until phase 3
of issue #84, from remote keystrokes too), so performing the write there froze the whole UI until the
foreground program read its stdin,
which it need never do: measured at 5.17 s for a paste into a `sleep 5`. Local keystrokes were never
exposed to it, arriving on the relay's own queue, which is what made this look like a remote-only
problem rather than a property of the write.

Two details, if you go probing. The block needs a completed line and not merely a full queue, because
`ptcwrite` parks when the queue is full and either the canonical queue is non-empty or the tty is
non-canonical, so a paste of one enormous line into a canonical tty does not park at all. And the queue
has to be serial: input order is as load bearing as output order, so a concurrent queue would scramble a
paste that arrives as several chunks.

**Where ordering is guaranteed, and why it is arranged that way.** Output order is the read source's:
one serial `DispatchSourceRead` per pty, with both destinations written from inside its handler, so
the hub and the surface see the same bytes in the same order. Terminal output delivered out of order
is corrupt on screen, and a caller that fanned these chunks onto unstructured `Task`s would corrupt
it, since two Tasks created in order can still run in either order. Input order is the pty master's.
A remote viewer's bytes are handed to the pty's writer on the thread that read them from the socket,
one message after another, and the writer queues them on the pty's serial queue in that order, so a
paste arriving as several messages cannot be reassembled scrambled. A `Task` per keystroke anywhere on
that path would break it.

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
- **`readOutput` keeps working.** The terminal's screen model outlives the child exactly as the
  surface does, so the last screen and the scrollback above it stay readable.

The pane is the one place that does not show the kept surface. A selected session that has ended gets
the stopped screen with a Restart button instead (`GhosttyPaneState.stopped`, issue #70); see
`docs/AsciiScreens/ContentView.md`. Taking the surface off screen costs a reader nothing: `readOutput`
answers from the model, which does not care what is displayed.

The reopen is what frees the surface and the model, through `TerminalService.discard`. It is a protocol method with a
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
  `PaneStreamHub` can count bells in the byte stream, but libghostty has already parsed both correctly,
  and reading titles out of the stream would need OSC 0 and OSC 2 handling that `OSCStringTracker` does
  not do. The hub's bell hook is therefore left unwired here, and while it is unwired the hub does not
scan the stream for bells at all.
- **Terminations** come from `GhosttyService`, because a child exiting is what a termination means here
  and the service is what reaps it.
- **Job names** are polled, as above.
- **Program status** (`OSC 7501`, with the `OSC 133 ; A` prompts and `RIS` resets that end its
  records) is read off the byte stream by `ProgramStatusTap`, because libghostty does not report it at
  all. It reaches the monitor from the terminal's read queue through one main queue block per event,
  which is FIFO, so a `done` cannot be overtaken by the `working` before it the way it could with a
  `Task` per event.

A title change and a close request can both arrive on libghostty's own thread, so both hop to the main
queue carrying the session id rather than the view: after the hop the surface may already be gone, and a
stale object pointer would be a use after free where a missing dictionary entry is simply nothing to do.
The runtime callbacks are C function pointers and cannot capture, so they reach the one host through a
weak static; a callback that has hopped must find nothing rather than resurrect a released host.

One subtlety in that C API is easy to get wrong and silent when you do: **the userdata of a surface
scoped runtime callback is the surface's own userdata, not the app's.** libghostty passes
`surface.userdata` to `close_surface_cb`, `read_clipboard_cb` and `confirm_read_clipboard_cb`, and the
app's userdata only to `wakeup_cb`.

## Program status (OSC 7501)

The [Program Status Protocol](https://gist.github.com/mitchellh/7acae3abd8355c1c00287d67e96c913a)
lets a program say whether it is working, waiting on the user, finished, or failed, and why. Claude
Code reports it from 2.1.295. What the app does with it (the row's indicator, banners, the setting)
is in `notifications.md`; this is how it gets read.

**libghostty does not help, and a newer one would not either.** The pinned build does not parse the
sequence, and upstream Ghostty's app runtime ignores it (`stream_handler.zig`); only the standalone VT
library exposes it, through a callback this embedding API does not have. So Wietty reads it from the
byte stream it owns. `ProgramStatusScanner` finds the reports, the support query, `OSC 133 ; A` and
`RIS` in raw output, keeping its state across chunks because a sequence can be split between two
writes, and applies the protocol's limits and validation (`ProgramStatusReport`) before anything is
stored. It is a per byte state machine that buffers only while inside an `OSC 7501` or `OSC 133`,
because it sees every byte every terminal prints.

**The support query has to be answered, and answered first.** A program that implements the protocol
asks `OSC 7501 ; ?` before it reports anything, and Claude Code puts a device attributes request right
behind the query so that every terminal answers something. Whichever reply comes back first decides:
if libghostty's answer to the device attributes request arrives before ours, the program concludes the
terminal has no support and stays silent for the rest of its run. libghostty answers as soon as it
reads the chunk, so `ProgramStatusTap` writes the reply (`OSC 7501 ; ? ST`, the only bytes the protocol
ever lets a terminal send back) while the relay still holds that chunk, before it is forwarded to the
helper. The reply goes through `RawPTY.write`'s serial queue, which is also the queue libghostty's own
replies reach the master through, so ours is queued ahead of anything libghostty can say about the same
chunk. That ordering is by construction; no test can show the race itself, because it needs a real
surface. `GhosttyServiceTests` does show that a child asking the question reads the exact reply.

**`Pst` in the bundled terminfo** advertises support too, as the protocol suggests. It is a hint only:
the query is authoritative, and over ssh or inside a multiplexer the entry may be missing.

## The server's own terminal

Every terminal has a second emulator beside the surface: a `TerminalScreenModel`, which is
libghostty-vt parsing the same bytes with no window, no renderer and no child. The surface can only
say what is on a terminal's screen while that terminal is displayed, in plain text and with no cursor.
The model answers for any terminal at any time, with colours, modes, the cursor and the scrollback.
Two things read it: the frames a remote viewer is sent, and `readOutput`.

`GhosttyService.open` builds one model per terminal, at the grid the pty is spawned with and with
grapheme clustering as the surface has it, and registers it in `SharedTerminalState` before the relay
starts reading. It is resized on the same report that resizes the pty, so its grid is the surface's:
the surface stays the sizing authority and the model is told, never asked. It is released when the row
is closed or reopened, together with the surface. An exited terminal keeps both.

**The model never answers the program.** A terminal replies to queries (device attributes, a cursor
position report) by writing to the pty, and the surface already does. A second answerer is a wrong
answer the moment the two disagree about any state, so the model is built with no reply callback and
no other callback either: the bell, the title and notifications are reported by the surface through
`GhosttyMonitor`, and a second report would ring every bell twice.

**What a model can produce**, every read answered from the same parse:

- The paint frame (`paintFrame()`): the visible viewport as VT, with colours, the cursor, modes, the
  scrolling region and the tab stops, for a terminal that has just had `TerminalPaint.reset` (a soft
  reset, an erase and a home). What a viewer that asked for repaints is sent after a resize
  (`repaintFrame()` gives it with its grid, both read under one acquisition of the lock, so a resize on
  the main actor cannot pair the frame of one grid with the size of another).
- The snapshot frame (`snapshotFrame()`): every row of history the model still holds, oldest first,
  then the active screen, then the same cursor, modes and the rest, as VT for a terminal that has just
  had `TerminalPaint.hardReset` (`ESC c`). It comes as one value, `TerminalSnapshotFrame`, with the grid
  and the screen it was taken on, all read under one acquisition of the lock, so a write can never land
  between the bytes and the flag. Written behind that reset into a terminal of the same grid, even one
  left on another program's alternate screen with mouse reporting, a scrolling region and kitty
  keyboard flags on both screens, it leaves the same history row for row, the same screen and the
  cursor on the same cell. A line the terminal wrapped arrives wrapped at the same column rather than
  as two lines, and the blank rows at the bottom of the screen are kept, so the history is neither a
  row short nor a row long. Measured at 120 columns with a full default scrollback of coloured log
  lines: about 630 KB in about 2 ms. At 100,000 lines: 6.4 MB in about 17 ms, in the debug test host.
  What a viewer is sent on attach and on a resync.
- Whether the alternate screen is the active one (`isAlternateScreen`).
- The plain text `readOutput` returns (`text(maxLines:)`), and the library's own binary snapshot
  (`snapshot()`), which is for restoring a terminal and not for painting one.

**The snapshot frame lays down its content with default modes and sets the modes after it.** The
library's own order is modes and tab stops in front of the content, and the scrolling region, the
cursor, the pen, the keyboard protocols and the character sets behind it. In front does no harm to a
viewport, but it does to wrapped history: with autowrap off on the source, every joined line would be
cut at the last column. So the frame is assembled from parts: grapheme clustering (mode 2027) stated
outright, because it decides how many cells a joined emoji takes and the reset puts back the
receiver's default rather than the source's; then the modes that must be in force before the content,
in the library's order (the switch to the alternate screen, and the column modes 3 and 40); then the
content with no extras; then the other modes and the tab stops; then everything the library writes
behind the content. The parts in front of and behind the content are cut out of the library's output
for the last row alone, and the part behind is taken from a pass that also wrote the modes, because
the cursor position the library writes is relative to the scrolling region only when that same pass
wrote origin mode.

Two tests guard this construction. The autowrap test is the only one that fails against the library's
single pass. The scrolling region test guards the cut: it fails when the part behind the content comes
from a pass that did not write the modes, since the cursor then lands two rows low. The tests for line
drawing and for left and right margins pass either way; they pin behaviour, not the order.

Modes 3 (132 columns) and 40 (allow the switch) are tracked by the library, which really changes the
grid and clears the screen. The library writes 3 before 40, so on a receiver just reset the 3 finds the
switch not allowed and does nothing: the receiver keeps the grid it was told and is left allowing the
switch, as the source is, but without mode 3 set. Not every receiver turns 40 off on a reset (SwiftTerm
keeps it, and honours mode 3), so the frame writes `?40l` in front of the 3 as well, and the library's
own 40 still follows it.

A frame that cannot be cut is a bug and says so. When any formatter pass fails (a failed pass is never
mistaken for an empty row), when the library's output does not have the expected shape, or when the
part in front holds a sequence the cut does not understand, the fault is logged as an error and the
frame is the library's single pass with mode 2027 stated in front of it, which is wrong only for a mode
that changes how content is laid down. Only the test host stops there, on an assertion
(`TerminalFrameFault`): a Debug build is what the app is run as day to day, and a terminal state nobody
foresaw must not take it down. Every failed formatter pass is logged too, wherever it happens, because
the empty paint or text it falls back to looks like a terminal with nothing to show. No test reaches
the fallback itself: it cannot be reached without a seam in the code, and none was added. The policy
(log always, stop only the test host) is tested on its own.

Two limits of the snapshot frame are known and not handled here:

- A frame taken on the alternate screen leaves the receiver's primary screen empty, and its saved
  cursor wherever the receiver had it. The hub answers that by sending a fresh snapshot when the
  terminal leaves the alternate screen (see "Serving a remote viewer"), which is the only remedy: the
  formatter has no documented way to write the screen that is not active.
- A cursor in the pending wrap state (a line written to the last column, nothing after it yet) is not
  restored, so on the receiver the next character overwrites the last column instead of wrapping. The
  paint frame has the same limit.

Both frames leave out the palette, for the reason given under "Serving a remote viewer". Both paint
the active screen only: on the alternate screen the snapshot frame is that screen with no history,
because the alternate screen has none, and the primary screen underneath is not in it. libghostty-vt's
formatter is documented to read the active screen. It will in fact format the primary screen while the
alternate one is active when handed a selection of tracked grid references taken on the primary screen
before the switch, but that is outside what the headers promise, and the cursor and modes it would add
are the alternate screen's. The other route, decoding the binary snapshot into a second terminal and
leaving the alternate screen there, works within the contract at the cost of copying the whole
terminal. Neither is used.

**One lock per model**, held for the whole of each call, because libghostty-vt is not reentrant and
its callers are on three queues: the relay's for a write, the hub's delivery queue for a paint, and
the main actor for a resize or a text read. What is called often is cheap (a parse runs at hundreds of
megabytes a second, a paint frame formats one viewport). One call is not: **a change of column count
reflows the whole scrollback under that lock**, and on a full scrollback that is slow enough to hold
the terminal's own output behind each notch of a window drag. It is a known cost and not yet solved.

**History is a setting**, `scrollback-lines` in `~/.config/wietty/config`
(`ProjectStore.scrollbackLines`, `TerminalScrollback`). It has no control in the settings panel yet:
nothing a user can see changes with it until the pane and the remote viewers read their history from
the model, which is phase 3 of issue #84. The default is 10,000 lines
per terminal and the range is 1,000 to 100,000; a value outside it, typed into the file by hand, is
brought to the nearer end. The number is a memory decision. A retained row costs roughly 1 KiB at 120
columns whatever is written on it, and the cost is only paid once the rows exist. Measured on ten
models at 120 by 40, each filled past its limit with plain lines: 10.2 MiB per terminal at 10,000
lines, 1.2 MiB at 1,000 and 99 MiB at 100,000. Thirty full terminals at the default are about 300
MiB. The library prunes a whole page at a time, so a full scrollback holds between its limit and about
one page under it, depending on where in a page the last line fell: with short log lines, 9,605 to
10,000 rows at the default and 120 columns, and 409 to 1,000 at the floor and 80 columns.

**The limit is read when a terminal opens.** `GhosttyService.open` asks for it once, on the main
actor, and builds the model with it, so a change applies to terminals opened afterwards and one that
is already open keeps what it started with. Neither the relay's queue nor the hub's ever reads the
setting. The service is built before the store that holds it, so `GhosttyStack.followScrollbackSetting(of:)`
is what points one at the other. The floor is there because below about a thousand lines an MCP read
starts coming back shorter than an agent asked for, to save under a megabyte per terminal; the ceiling
is where a typo in the file stops being able to take the machine with it.

This is the server's history and not the pane's. The surface keeps its own, sized by Ghostty's
`scrollback-limit` in the user's Ghostty configuration, and that is what the Mac's pane scrolls
through. The setting here decides how far `readOutput` can reach.

The two libraries share several hundred symbols. `scripts/coexistence-check.sh` is the run that shows
they agree in one process, under the address sanitizer, with a real surface; `CLAUDE.md` describes it.

## Serving a remote viewer

The producer is `TerminalRelay` writing into `PaneStreamHub.write`, so the bytes on the wire are the
child's own, exactly: the hub delivers `StreamMessage` values (from `wietty-shared`) and a `data`
message carries the bytes as they were read, with nothing decoded, replaced or held back. A viewer's
terminal decodes them, as it would from any pty. `docs/remote-access.md` is the protocol reference. The
things worth stating here follow.

**A viewer is first sent the grid and a snapshot.** On attach the hub sends a `resize` with the grid,
then a `snapshot` (on the wire both come after the server's `hello`, which the route queues before it
attaches): `TerminalPaint.hardReset` (`ESC c`) and the model's snapshot frame, which is the
history the model holds, the screen, the cursor, the modes, the scrolling region and the tab stops.
The reset is the hub's and appears once; the frame carries none of its own. Two things are deliberately
not in it:

- The palette. The formatter can restore all 256 entries with `OSC 4`, but what it would write is the
  model's own table, which nothing configures: the library's default colours, not the theme the
  surface draws with and not the theme of the viewer. Sent, it would replace the viewer's colours with
  a third set. Left out, a viewer draws indexed colours with its own theme, as it does for the stream.
- The screen underneath an alternate screen. A viewer attaching while a full screen program runs gets
  that program's screen. The hub remembers such a viewer, and sends it a fresh snapshot when the
  terminal leaves the alternate screen (see below).

**A grid that moves** is told to every viewer with a `resize`. What else a viewer gets depends on the
mode it attached with (`ResizeMode`). A `repaint` viewer is also sent a `repaint`: the model's paint
frame of the visible screen behind `TerminalPaint.reset`, a soft reset, an erase and a home, because the
frame itself erases nothing and it lands on a viewer that already shows something. It is not a hard
reset, which would also throw away the viewer's history, on every notch of a window drag. A `reflow`
viewer reflows by itself and gets nothing more.

**A viewer that lost its place is resynchronised.** `resync(connectionId:onUnavailable:)` makes the
same join as an attach for one viewer that is already there: the other viewers get the outstanding
bytes, and this one gets a `resize` and a `snapshot`. It is what a `ViewerQueue` asks for when it
overflows. It is always answered: either the snapshot comes, or `onUnavailable` is called, when the
viewer or its session is gone or no snapshot could be built. The answer comes later, on the delivery
queue, because the request comes from inside a delivery to that very viewer, while the bytes of that
delivery are still on their way to the viewers after it. Run on the spot, the join would hand those
viewers the next bytes before the current ones.

**Between the hub and a socket.** `RemoteServer`'s attach route gives each viewer an `AttachedViewer`:
a `ViewerQueue` bounded at 4 MiB that `onMessage` pushes into, so a slow socket never holds up the
delivery queue, and one writer task per socket that drains it in order. The server's `hello` is pushed
before the attach, so it is the first frame. An overflow asks for a resync through `ResyncThrottle`, at
most one per viewer per 250 ms, because each one formats the whole history on the delivery queue under
the session's lock; requests in between fold into one that runs when the interval is over. The writer
and the reader of a socket are two child tasks, and whichever ends first ends the other, after which
the viewer is detached and its queue finished. `docs/remote-access.md` has the wire side.

**The alternate screen rule.** A viewer whose last snapshot was taken on the alternate screen holds an
empty primary screen underneath it. While such a viewer exists, the hub asks the model after each
write, under the session's lock, whether the alternate screen is still active (`onAlternateScreen`). When
it is not, every viewer it remembered is resynchronised and forgotten. A viewer that attached on the
primary screen already has the screen underneath and is never resynchronised by this. There is no
documented way to have the formatter write the screen that is not active, so a fresh snapshot once the
program has left is the design, not a stopgap.

**The frames and the stream meet at one byte.** An exact snapshot only helps if the stream picks up at
the very byte the snapshot stops at. One chunk early and a build log shows lines twice; one chunk late
and lines are missing. So the hub is the single place that knows the offset, and it holds one lock per
session to keep it:

- `write` appends a chunk to the session's buffer and writes it into the model (`onIngest`) under
  that lock, as one step. Whenever the lock is free, what the model has parsed and what the hub has
  accepted for delivery are the same bytes.
- `attach` takes the lock and does three things before releasing it: it takes what is buffered, asks
  for the snapshot (`onSnapshot`), and registers the viewer. The bytes taken go to the viewers that were
  already there and not to the new one, whose snapshot already holds them. Everything accepted
  afterwards goes to all of them.
- A resync makes the same join for one viewer, and a resize the same join for the repaint: what was
  accepted before the frame is delivered ahead of it, and everything after follows it.

Nothing is delivered under a lock. What a join or a flush takes under the session's lock is handed to
the viewers after the lock is released, on one serial delivery queue for the whole hub: the flush
timer, a quiet flush, an attach, a resync, a resize and an ending each take bytes and then hand them to
viewers, and two of those running at once could take in one order and deliver in the other. `attach`
runs on that queue synchronously, which is what puts a viewer's snapshot ahead of its first stream
bytes. A viewer's `onMessage` is therefore always called on that queue with no lock of the hub held, so
it may ask for a resync; it must not call `attach` or `flush`, which wait for the queue.

The lock is per session because a parse runs under it, and one terminal printing a build log must not
hold up the bytes of the terminal next to it. For the same reason the flush is cheap under it, a swap
of the buffer and the list of viewers and nothing else, and the flush timer never waits for a session's
lock: a session whose model is busy (a reflow after a resize can hold a write for a long time) is
skipped for that tick and its bytes go out on the next one, so the viewers of every other terminal keep
receiving. Until phase 3 of issue #84 the flush also decoded the bytes into text under that lock, byte
by byte, and that alone capped a terminal at about 3 MiB/s.

**Coalescing, and a quiet terminal.** Output is delivered on an 8 ms timer, so a burst coalesces into
one message. A write into an empty buffer when the session's last flush is more than 8 ms old is
delivered at once instead, so the echo of a keystroke on a quiet terminal does not wait for the next
tick. A steady stream still goes out on the timer. The rule applies only to a session with a viewer:
a write nobody watches would be flushed to nobody, so it stays in the buffer for the next tick, which
empties the buffer of every session, watched or not.

Two things keep the join honest at its edges. A character cut by the moment of a join reaches the
viewer whole: the model has its first bytes and has drawn nothing of it, so the frame does not hold it,
and the rest arrives in the stream after the frame. So the hub keeps the last bytes of the stream when
they start a character that has not finished (at most three, found from the last four bytes of each
write) and puts them behind a snapshot or a repaint. An escape sequence cut by that moment is not
protected in the same way: the model has consumed its first half, and the viewer receives the second
half as text. It takes a join landing between two reads that cut a sequence, and the next redraw
corrects it.

`PaneStreamJoinTests` races a writer against an attach and against repaints, plays everything the
viewer was sent into a terminal of its own, and asserts every numbered line is there exactly once.
`PaneStreamResyncTests` covers the resync, the alternate screen rule, the quiet flush and input.
`ViewerResyncTests` covers the rate limit, and `RemoteAttachRouteTests` the route on a real socket.

**A viewer is also told when the grid moves**, which takes wiring here rather than coming for free. A
viewer learns its size on attach and from nothing else on the socket, so a window resize would
otherwise leave every already attached viewer rendering reflowed bytes against the old grid until it
reattached. The report comes from the surface, so `GhosttyService`'s resize handler carries it into
`PaneStreamHub.noteSize`. Two details are load bearing. The hub deduplicates on the last size it saw,
because libghostty reports a grid on events that need not have moved it (a font metric change, a
re-parent). And the service resizes the model *before* it reports the size, because the report is what
makes the hub repaint and the repaint is taken from the model: reported first, it would paint the screen
as it was before the reflow and then be contradicted by the bytes the reflow produced.

The hub can also take the grid from a viewer, through `PaneStreamHub.claim(connectionId:cols:rows:)`,
which nothing calls yet. A claim and `noteSize` share the one record of the grid in force. A claim for a
new grid is handled on the hub's delivery queue: the hub calls `onClaim` (wired to the resizer
`GhosttyService` registers in `SharedTerminalState`, which resizes the pty and then the model) and then
repaints as above, with `own` true in the claimant's `resize` only. A claim for the grid already in force
resizes nothing and is answered to the claimant alone, with one `resize` whose `own` is true. A grid the
surface reported that a claim has overtaken before its repaint ran is not announced.

The direction of these hooks matters as much as their order. The resize report runs on the main actor
and hands the size to a lock guarded hub. A claim's resize runs on the hub's delivery queue instead,
and reaches the pty and the model through `SharedTerminalState`, never through the service. The census, the model feed, the frames and the input writer
are asked by the hub from the relay's queue, from its own, and from the thread a viewer's input
arrived on, and answer from `SharedTerminalState` and the model, both lock guarded. Nothing on a hub
queue reaches back into the main actor isolated service.

**A viewer is told when the terminal ends**, and that also takes wiring here. The census answers an
attach that has not happened yet; a browser or an iPad already watching a session has nothing else to
learn from, because the terminal is a PTY in this process. So `GhosttyService` reports a stream that
is over through its own hook, which `GhosttyStack` wires to `PaneStreamHub.endViewers(ofSession:)`.
Both ways a terminal ends are reported: the child exiting, and the row being closed. The bytes still
buffered are delivered ahead of the ending. Without the hook a viewer went silent forever, which is
indistinguishable from an idle terminal and is exactly the state the census exists to prevent for a
viewer arriving later.

A frame that could not be built is never an empty screen: a session whose model is gone gives no
snapshot and no repaint, and the hub logs it. A new viewer then starts from the stream alone, a resync
answers `onUnavailable`, and on a resize the viewer is sent the bare `resize`.

## Reading a terminal's output

`GhosttyService.readOutput` answers an MCP read of what a terminal has printed, from the terminal's
screen model: `TerminalScreenModel.text(maxLines:)`. It returns the last `maxLines` lines, most recent
last. A line the terminal wrapped comes back as one line, which is how the surface reported its text
and what a reader counting lines means by one. Trailing spaces are removed, and the blank rows below
the last line with text are not lines.

**It does not matter what is displayed.** This is the reason the read moved. The surface only answers
while it is on screen, and in a one window app that is one terminal: every other read, which is nearly
every read an agent makes, used to fall back to a single recorded viewport however many lines were
asked for. The model holds the scrollback for every terminal, displayed or not, running or exited, and
reaches as far into it as the caller asks, up to the lines it keeps (the `scrollback-lines` setting,
10,000 by default).

The read formats only the rows it needs. It starts from the active screen plus one row per line asked
for, and widens while wrapped lines leave it short, so a small read stays cheap on a deep scrollback.
A window that does not start at the top of the history can start in the middle of a wrapped line; that
first partial entry is dropped and never returned.

**The surface can still be read, by one caller.** `GhosttySurfaceHost.readText` wraps
`ghostty_surface_read_text` and is not part of `TerminalSurfaceHosting`. It exists for the coexistence
check, which has to ask the surface itself what it drew in order to compare it with the model. Two
facts about it are worth keeping. The coordinate mode decides the span, not the point tag:
`GHOSTTY_POINT_COORD_EXACT` addresses a row, while `TOP_LEFT` and `BOTTOM_RIGHT` mean "the extreme of
this space", so a `GHOSTTY_POINT_SCREEN` selection between those two is the whole screen with its
scrollback, and `EXACT` clamps to the grid and cannot address history at all. And the two reads cost
very differently: measured on a 50,000 line scrollback, the viewport read is 0.14 ms and the whole
screen read 29 ms plus 5 ms to decode, which is why a read of exactly the grid's own height takes the
cheap path (`GhosttySurfaceHost.readsScrollback(maxLines:gridRows:)`, with a test at the boundary).

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
(above, and `RawPTY.terminalType`, which reads `BundledTerminfo`), `TERM_PROGRAM` and
`TERM_PROGRAM_VERSION` name who is drawing it: `Wietty` and the bundle's version. All three are set
unconditionally, because the child's environment starts as Wietty's own and every one of them would
otherwise carry an answer about a different terminal. Both `TERM` and `TERM_PROGRAM` decide whether an
agent announces itself, and recognition is by an exact value. A program reads `TERM_PROGRAM` to learn
what its host is (iTerm2 answers `iTerm.app`, Ghostty.app `ghostty`, Apple's Terminal
`Apple_Terminal`). Some tools read `TERM` instead: Claude Code treats `TERM` of `xterm-ghostty` as a
Ghostty terminal and only then emits a desktop notification (`OSC 777`), answering a host it does not
recognise with a bare bell. That is why the bundled `xterm-ghostty` terminfo matters past rendering
(`BundledTerminfo`, `docs/notifications.md`): under the `xterm-256color` fallback the agent sees an
unknown terminal, emits no notification, and the user gets no 🔔 and no banner. An app launched from
the Finder inherits no value at all, so setting all three is the ordinary case rather than the
exception. `COLORTERM` is set to `truecolor` for the same reason `TERM` is `xterm-ghostty`: libghostty
draws 24 bit colour, and a program that reads `COLORTERM` rather than the terminfo capability to decide
whether to emit truecolor would otherwise fall back to 256.

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
- **A remote viewer's first paint carries the viewport and nothing above or beneath it.** No
  scrollback, and not the screen under an alternate screen. Causes above, under "Serving a remote
  viewer".
- **The palette is left out of the paint frame, on purpose.** A viewer draws indexed colours with its
  own theme, for the paint as for the stream, so the same terminal can look different on the Mac, in the
  browser and on the iPad. What the model could send is the library's default table, which is neither
  the surface's theme nor the viewer's, so sending it would be a third set of colours rather than the
  right one. A program that changes the palette itself with `OSC 4` reaches a viewer attached at the
  time, through the stream, and not one that attaches later.
- **An escape sequence cut exactly at the moment a viewer attaches shows its second half as text.**
  The model has consumed the first half, so the snapshot cannot hold it, and the new viewer's stream
  starts in the middle of the sequence. It takes an attach landing between the two reads that cut a
  sequence, it affects only the viewer that attached, and the next redraw corrects it. A character
  split the same way is protected: the hub puts its first bytes behind the snapshot. An escape
  sequence is not.
- **A column change reflows the whole scrollback under the model's lock**, so the output of the
  terminal being resized waits behind it, on each notch of a window drag once its scrollback is full.
  Other terminals are not held: the lock is per session and the flush timer skips a busy one. The cost
  grows with the `scrollback-lines` setting. See "The server's own terminal".
- **The scrollback limit and grapheme clustering are both read when a terminal opens.** A terminal
  that is already open keeps the history limit it started with after `scrollback-lines` changes, and
  keeps the clustering mode its surface resolved from the Ghostty configuration at that moment
  (`grapheme-width-method`), so a change to either reaches terminals opened afterwards. For clustering
  the surface behaves the same way, which is what keeps the two emulators agreeing on how many cells an
  emoji takes.
- **The stream carries whatever `RawPTY.terminalType` resolved**, which is `xterm-ghostty` in the
  ordinary case: the app compiles that terminfo entry into its own bundle and points the child at it
  with `TERMINFO_DIRS` (`BundledTerminfo`, and "Spawning the shell" above), so no other terminal has to
  be installed for the truthful name to be usable. It falls back to `xterm-256color` only when a build
  did not produce the bundled entry. Either way a remote client may receive sequences it does not
  implement, because the bytes are the child's own; see `docs/remote-access.md`.
- **The workspace badge setting does nothing here.** libghostty has no title setter of any kind, so the
  badge travels as the surface's initial title and reaches only the host's own record and the view's
  accessibility label. It is still passed rather than dropped, so that the day the C API grows a setter
  the value is already there.
- **libghostty can never render a remote session.** There is no way to feed bytes into a surface, which
  is the same fact that forces the helper. `RemoteTerminalView` therefore stays on SwiftTerm, and the
  local pane and the remote terminal window do not look alike.
- **An exited shell leaves a notice on its surface.** libghostty draws "Process exited. Press any key to
  close the terminal." and its close request only arrives with that next key. The pane never shows it:
  once the session has ended, `LocalTerminalView` draws a stopped screen with Restart instead of the
  surface (`GhosttyPaneState.stopped`, issue #70). Wietty does not set
  `ghostty_surface_config_s.wait_after_command`, so this is `ghostty_surface_config_new`'s default
  rather than a choice made here. It costs nothing: the row's own state comes from the relay reaching
  EOF, through `GhosttyService.reap`, which is the one path that knows whether the shell exited.
  `GHOSTTY_ACTION_SHOW_CHILD_EXITED` is deliberately left unhandled for the same reason, and answered
  false so libghostty knows nothing was shown. On this substrate the surface's command is the helper,
  which ends because the terminal ended rather than the other way round, and the action also fires
  when the app tears a terminal down itself, so it says nothing about whether the shell exited.
- **The surface is kept after the child exits**, and so is the terminal's screen model, which is what
  keeps that last screen and its scrollback readable through `readOutput` and the MCP server while the
  pane shows the stopped screen.
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
`NSView` and cannot exist without one, that there is no title setter, and that the `exec` backend
offers no byte feed. What the surface can be asked about its own screen no longer matters to the app,
which reads the screen model instead; only the coexistence check still calls
`ghostty_surface_read_text`. `GhosttySurfaceHost.libraryVersion()` logs the linked library's own version at
startup; because the pin is exact, a mismatch between that and `project.yml` means a stale resolved
package rather than a version range.

A first resolve of this package can park indefinitely on a keychain prompt, with near zero CPU and an
empty artifacts directory. It is not the "cannot lock ref" failure and clearing caches does not help.
`CLAUDE.md` carries the workaround under "A first build can hang on package resolution".

## Where the terminal lives

Everything above except the surface is in `WiettyCore`, a framework target that imports
neither SwiftUI nor AppKit. The pty, the relay, the stream hub, the service and the
stack are all there; `GhosttySurfaceHost`, the one type that touches libghostty and an
`NSView`, stays in the app. The split is not for reuse. It is so the compiler refuses
an import of the UI on the side that will become a separate process in phase 5 of issue
#84, years before the process is cut.

Two seams follow from it and are worth knowing before changing this code.

**The surface protocol is in two halves.** `TerminalSurfaceHosting` is the AppKit free
one and lives in the core beside the service that uses it. `TerminalSurfaceViewing`,
which is the single method returning an `NSView`, is in the app, and the pane reaches a
view through `TerminalStack.surfaceView(for:)`. `GhosttySurfaceHost` conforms to both.

**The service does not decide what the pane shows.** It used to: `focus` answered
whether a session was alive and selected it while answering, so an MCP tool call or a
tap on an iPad moved the Mac's pane as a side effect. `focus` is `probe` now and only
answers. Showing a terminal is a request: the service raises one when a terminal is
opened, when the displayed one is closed and another remains, and when everything is
torn down, and `ProjectStore` raises `StoreEvent.showTerminal` when a row is asked for.
`TerminalSelection`, owned by `WiettyApp` and wired by `TerminalSelectionWiring`,
honours them synchronously, so with a window open the pane moves exactly when it did
before. The service still has to be told which terminal is displayed, through
`displayedSessionChanged(from:to:)`, because libghostty reads an off screen surface as
empty and the one leaving the pane has to have its screen recorded on the way out.
