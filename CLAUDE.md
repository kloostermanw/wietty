# Wietty

The macOS app: a workspace manager with its own terminal, which also **serves** the LAN remote
protocol and consumes it as a client.

## Project
This app is one of three repositories. The wire format of the LAN remote protocol is defined once,
in `wietty-shared`, so a protocol change must not be applied twice.

|name          | target  | github                                        | path                  |
|--------------|---------|-----------------------------------------------|-----------------------|
|wietty        | mac os  | https://github.com/kloostermanw/wietty        | ~/repos/wietty        |
|wietty-ios    | ipad os | https://github.com/kloostermanw/wietty-ios    | ~/repos/wietty-ios    |
|wietty-shared | library | https://github.com/kloostermanw/wietty-shared | ~/repos/wietty-shared |

Which side of the remote protocol lives where decides which repo a bug belongs in:

- **Served side, only here.** `RemoteServer`, `LocalStreamServer`, `WorkspaceSerializer`,
  `RemoteAccessToken`, and the terminal itself: `GhosttyService`, `RawPTY`, `TerminalRelay` (which
  only reads the pty; input reaches the pty through the writer the service registers),
  `PaneStreamHub`, the server's own screen model (`TerminalScreenModel`, `GhosttyVtTerminal`),
  `GhosttySurfaceHost` with the pane's bridge, and the bundled `wietty-pty` helper. All of those
  are in the `WiettyCore` target except `GhosttySurfaceHost` and the bridge, which stay in the app
  because the surface is the one thing that touches an `NSView`. A rendering or streaming fault
  reaches every client of the stream (the browser, the iPad, another Mac's remote pane, and this
  app's own pane), so reproduce it here before suspecting a client. This app's own pane is a client
  of the stream like the others: its libghostty surface is fed from the stream, through
  `LocalStreamServer`, the pane's `LocalSocketLink` and its `TerminalBridge`. So a fault seen in the
  pane and in every other client is the stream's or the model's, and one seen only in the pane is
  the surface's or the bridge's. A terminal of another Mac is shown here by the same kind of
  surface and bridge, fed by `RemoteSocketLink` over `WS /attach`; it is a client like the iPad,
  so a fault seen only there is in that pane (`RemotePane`), not in the serving Mac.

- **Controlling side, in `wietty-shared`.** `RemoteWorkspaceStore`, `RemoteWorkspacesController`,
  `TerminalStreamConnection`, `RemoteSnapshotDecoder`, `RemoteConnection`, `SecretStore`. This app
  consumes them, the stream connection through `RemoteSocketLink`; `RemoteProjectAdapter` maps the
  package's `RemoteWorkspace` onto the local `Project` type and is deliberately not in the package.
  The package's `RemoteTerminalConnection` is the iPad's, and this app no longer uses it.

- **The stream's messages, in `wietty-shared` for both sides.** `StreamMessage` is the one type
  both ends of a terminal stream speak, so the served side uses the package too: `WiettyCore`
  links `WiettyShared` as well as the app, and `ViewerQueue` holds `StreamMessage` values for one
  viewer. Linked into more than one target, the package is built as a dynamic framework, and
  `WiettyTests` has to link it explicitly (see `project.yml`). Xcode copies that framework into the
  app and into the test bundle too, whatever `embed` says. Every copy has the same install name, so
  dyld loads one image of it (in a Debug test run, the one in `Build/Products/Debug/PackageFrameworks`);
  `WiettySharedImageTests` fails if a change ever makes it load two.

**One terminal.** A terminal is a pseudo terminal the app spawns and owns, rendered by libghostty in
the main window's pane. Nothing needs to be installed for it: no iTerm2, no tmux, not even
Ghostty.app. `TerminalStack` builds it at launch and there is nothing to choose. See
`docs/terminal.md`.

`docs/remote-access.md` is the protocol reference for all three repos.

## Two targets
The app is split in two, and the split is enforced by the compiler rather than by convention.

- **`WiettyCore/`** is everything Wietty does that needs no window: the store, the terminal byte
  path, the supervisors, the MCP and LAN servers. It imports neither SwiftUI nor AppKit, and must
  not start. That is the point: phase 5 of issue #84 makes it a separate process, and the boundary
  is being held years before the process is cut.
- **`Wietty/`** is the frontend: every view, `WiettyApp`, `GhosttySurfaceHost`, `UIPreferences`,
  `ServerRuntime`, `TerminalSelection`, and the pane's side of the terminal stream: the bridge each
  surface's helper connects to (`TerminalBridge`, made per surface by `OwnPaneBridge` and
  `PaneBridges`), its link to `LocalStreamServer` (`LocalSocketLink`, behind `TerminalStreamLink`),
  and what decides when the pane claims the grid (`PaneGrid`, carried out by `OwnPaneGrid`). The
  pane of a terminal on another Mac is frontend too: its link (`RemoteSocketLink`), its owner and
  registry (`RemotePane`, `RemotePanes`, with `ObservedLink` and `RemoteReconnectPolicy`), and the
  filter that keeps its size queries' answers from the other Mac (`SizeAnswerFilter`).

Members the app or the tests need are `package`, never `public`. The three targets share a
`SWIFT_PACKAGE_NAME`, so `package` reaches all of them and nothing outside sees a line of it. A
`public` added here is almost always a mistake: check the diff for one.

## Setup
This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen). `project.yml` is the source of
truth for the Xcode project; `Wietty.xcodeproj/` is generated and gitignored.

After cloning, or whenever `project.yml` or the source file layout changes, regenerate the project:

```sh
brew install xcodegen   # once
xcodegen generate
```

Regenerate after switching branches too: the project file is not tracked, so a branch that adds or
deletes sources leaves a stale file list behind and the test count silently changes.

### A first build can hang on package resolution

Two dependencies are binary artifacts, each served by a different host, and SwiftPM asks the
keychain for credentials for the host serving one:

| artifact | size | host | declared in |
|---|---|---|---|
| `GhosttyKit` | 52 MB | `github.com` (a release asset of `Lakr233/libghostty-spm`) | `project.yml` |
| `GhosttyVt` (libghostty-vt) | 16 MB | `release.files.ghostty.org` | `Packages/GhosttyVt/Package.swift` |

From a non interactive session nobody can answer that prompt, so `xcodebuild` parks in
`BinaryArtifactsManager.download` with near zero CPU and an empty directory under
`SourcePackages/artifacts/` (`libghostty-spm/libghostty/` for the first), for as long as you let it.
It is not the "cannot lock ref" failure and clearing caches does not help. The prompt is per host,
so a cache that already holds one artifact says nothing about the other. `xcodebuild` cannot turn
the keychain lookup off, the `swift` CLI can, and the artifact cache is shared, so warm each once:

```sh
swift package --package-path <a scratch package depending on libghostty-spm> \
  --disable-keychain --disable-netrc resolve
swift package --package-path Packages/GhosttyVt --disable-keychain --disable-netrc resolve
xcodebuild -scheme Wietty -destination 'platform=macOS' -resolvePackageDependencies
```

`GhosttyVt` needs no scratch package: the wrapper in `Packages/GhosttyVt` is one, and resolving it
leaves only a gitignored `.build` directory behind. The download itself takes a few seconds once the
keychain is out of the way. If `xcodebuild` is already parked, kill it and warm the cache, waiting
does not help.

Running the test suite is safe for your own settings. `WiettyTests` is hosted by the app, so a run
launches Wietty, and its defaults used to resolve to the real `~/.config/wietty/`. Under a test host
they resolve into a sandbox instead (see `TestHost`), so a run no longer rewrites your config,
`ghostty.cfg` or prompt templates, and no longer strips the session ids of your live terminals.

Build and test from the command line:

```sh
xcodebuild -scheme Wietty -destination 'platform=macOS' build
xcodebuild -scheme Wietty -destination 'platform=macOS' test
```

### The coexistence check

libghostty (the surface, linked into the app) and libghostty-vt (terminal state with no window,
linked into `WiettyCore`) share several hundred symbols and run in one process. That they can is
proven by one test the normal suite skips, because it needs a real window and a Metal device:
`GhosttyVtCoexistenceTests` feeds a real surface and a `GhosttyVtTerminal` the same five megabytes
and compares their visible grids. Run it, with the address sanitizer, after changing the pin of
either library:

```sh
scripts/coexistence-check.sh
```

Quit Wietty first. It opens a window for a few seconds. The sanitizer build replaces the normal one
in derived data, so the run takes a few minutes and so does the next ordinary build. In an ordinary
test run the suite is counted and reported as skipped.

### The imposed grid check

The own pane shows a grid another viewer chose by giving the surface's view exactly the size that
belongs to it: `(cols * cell_width_px + padding_x) / scale` by the same for rows, where the padding is
both sides together, `2 * window-padding * scale` in pixels (`SurfaceMetrics`). `ImposedGridMeasurementTests`
sets that size on a real surface in a real window for seven grids and reads the grid back from the
surface and from `stty size` in its child, at the display's scale and at the other one (1 or 2,
simulated by a window that reports it, so the display is never touched), with the default padding,
with one that is not, and with two values per axis and `window-padding-balance` on. Each grid is set
by hand on the bare view and then through the pane's own API (`impose(grid:on:)` with the view in
its `SurfaceContainerView`, sized from `metrics(id:)`). It prints one line per grid and variant
starting with `IMPOSED`, and `IMPOSED-EXTRA` lines for paths that need a real surface: a grid imposed
off screen and then shown, a scale change with a grid imposed, a reload that changes the padding, and
a program setting and resetting the background (`OSC 11`, `OSC 111`), which the margin follows. Run it after changing the pin of libghostty, or the way a pane sizes its
surface:

```sh
scripts/imposed-grid-check.sh
```

Quit Wietty first. It opens a window for about a minute. The padding goes into the sandbox's
`ghostty.cfg`, never your own. In an ordinary test run the suite is counted and reported as skipped.

### The reload surface check

A colour change in Settings calls `reloadConfig()` on the one `GhosttySurfaceHost`, and the next
terminal opened creates a surface on it. `ReloadThenCreateSurfaceTests` runs reload then create 25
times in each of four ways: a fresh host each time, one host, one host with the sandbox's
`ghostty.cfg` changed before every reload, and one host with a surface kept alive through every
reload. It prints one line per way starting with `RELOAD`. Run it after changing the pin of
libghostty or `reloadConfig()`, and with `--asan` for the address sanitizer (that build replaces the
normal one in derived data, as the coexistence check's does):

```sh
scripts/reload-surface-check.sh [--asan]
```

Quit Wietty first. It opens a window for about ten seconds, and a display must be awake: with every
display asleep, libghostty cannot create a surface's display link and fails the surface with
`error.OutOfMemory`, which once passed for a reload bug. In an ordinary test run the suite is
counted and reported as skipped.

### The remote surface check

`RemoteSurfaceMeasurementTests` measures a terminal of another Mac shown in a libghostty surface, with
a real `RemoteServer` on 127.0.0.1 and a throwaway token: a snapshot fed through the bridge and the
helper to a surface its child left dirty, compared with a clean surface and with the model, also on
the alternate screen and, through `RemotePanes`, at a grid other than the surface's (R1); backpressure
through the package's WebSocket client (R2); the cost of a show and a hide through `RemotePanes` and of
100 of each (R3); large snapshots through the helper (R4); the ends that stop the helper (R7); fast
hides and shows, with and without the host's drain on destroy (R8); a reconnect on a kept dirty surface
through `RemotePanes`, the server dropped and back, compared with the server's terminal (RECONNECT); a
viewer surface's clipboard and dropped events; and `RemoteSurfacePane` in a window (PANE). It prints
lines starting with `STEP5`. Run it after changing the pin of libghostty, the bridge, the helper, the
remote pane, the package's stream client or `GhosttySurfaceHost` (its viewer surfaces, `reloadConfig`,
`destroySurface`): the closed clipboard, the dropped events and the drain on destroy are covered by
this gated suite only.

```sh
scripts/remote-surface-check.sh [test name]
```

Quit Wietty first. It opens a window for several minutes and needs a display awake. In an ordinary
test run the suite is counted and reported as skipped.

### The stream baseline

`StreamBaselineTests` measures the terminal byte path from where `wietty-pty` stands, with the
relay, `ProgramStatusTap`, `PaneStreamHub`, the libghostty-vt screen model, `LocalStreamServer`, the
pane's `LocalSocketLink` and its `TerminalBridge` in the path as the app has them. It prints
four lines starting with `BASELINE`: the echo of one keystroke on a quiet terminal, the same while
the main thread is busy for 50 ms out of every 60, and how fast 100 MB of output arrives, once as one
endless line (`throughput-oneline`) and once as ordinary 80 character lines (`throughput-lines`). It
runs in the Debug build the test target uses, so its throughput is lower than a release build's. The
normal suite skips it. Run it before and after any change to the byte path, and compare:

```sh
scripts/stream-baseline.sh
```

Quit Wietty first, because the test host is the app. No window of the host was seen on screen
during a run (checked every five seconds, so a window shown for less than that could be missed).
Compare each number only with itself before and after a change, never the two echo numbers with each
other. The busy variant reports a shorter delay than the quiet one, most likely because the spinning
main thread keeps the CPU out of its idle states, so the two are not comparable with each other. The
busy line also reports the share of the run the main thread really spent spinning, and the test
fails when that is under half of the intended 50 out of 60. Run it three times. Now and then one
run comes out shifted as a whole, more than about 20 % away from the other two on some number; when
that happens, run a second set of three and keep both.

## Documentation
The `docs/` folder must stay in sync with the code it describes. Whenever you change
something a document covers, update that document in the same change. For example,
`docs/AsciiScreens/` holds one ASCII layout per SwiftUI view (`ContentView.md`,
`WorkspaceCardView.md`, `SettingsView.md`, and so on), so editing a view means updating its matching
file (and adding a new file when you add a view worth documenting). A view whose layout is already
drawn inside a parent's file, as the remote sidebar section is inside `ContentView.md`, is
documented there rather than duplicated into a second file that would drift.

Never use dashes (— or -) as punctuation in documentation or README files. Rephrase using periods,
commas, or parentheses instead.

## General
Do not tell me I am right all the time. Be critical. We're equals. Try to be neutral and objective.
Do not excessively use emojis.

## Using GitHub
For questions about GitHub, use the gh tool.
Never mention Claude Code in PR descriptions, PR comments, or issue comments.
Do not include a "Test plan" section in PR descriptions.

## Git
use `/create-commit force` to create a commit message
use `/create-pr force` to create a pr message

A global `commit-msg` hook rejects any commit message containing a word from
`~/.config/git/disallowed-words.txt`, matched whole-word and case-insensitively. That list currently
includes `claude`, `Co-Authored-By`, `wip`, `temp`, `fixme`, and `foobar`, so a "wip:" subject or a
co-author trailer is refused. Reword the message; do not work around it with `--no-verify`.
