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

- **Served side, only here.** `RemoteServer`, `WorkspaceSerializer`, `RemoteAccessToken`, and the
  terminal itself: `GhosttyService`, `TerminalRelay`, `RawPTY`, `PaneStreamHub`, the server's own
  screen model (`TerminalScreenModel`, `GhosttyVtTerminal`), `GhosttySurfaceHost` and the bundled
  `wietty-pty` helper. All of those are in the `WiettyCore` target except `GhosttySurfaceHost`,
  which stays in the app because it is the one type that touches an `NSView`. A rendering or
  streaming fault reaches every client of the stream (the browser, the iPad, and another Mac's
  remote pane), so reproduce it here before suspecting a client. This app's own pane is not one of
  them until phase 3 of issue #84: it shows the libghostty surface, so a fault seen only there is
  the surface's and one seen only by a client is the model's or the stream's.

- **Controlling side, in `wietty-shared`.** `RemoteWorkspaceStore`, `RemoteWorkspacesController`,
  `RemoteTerminalConnection`, `RemoteSnapshotDecoder`, `RemoteConnection`, `SecretStore`. This app
  consumes them; `RemoteProjectAdapter` maps the package's `RemoteWorkspace` onto the local
  `Project` type and is deliberately not in the package.

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
  `ServerRuntime`, `TerminalSelection`.

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

### The stream baseline

`StreamBaselineTests` measures the terminal byte path from where `wietty-pty` stands, with the
relay, `ProgramStatusTap`, `PaneStreamHub` and the libghostty-vt screen model in the path as the app
has them. It prints
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
