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
  terminal itself: `GhosttyService`, `TerminalRelay`, `RawPTY`, `PaneStreamHub`,
  `GhosttySurfaceHost` and the bundled `wietty-pty` helper. A rendering or streaming fault
  reaches every client (browser, this app's own pane, and the iPad), so reproduce it here before
  suspecting a client.

- **Controlling side, in `wietty-shared`.** `RemoteWorkspaceStore`, `RemoteWorkspacesController`,
  `RemoteTerminalConnection`, `RemoteSnapshotDecoder`, `RemoteConnection`, `SecretStore`. This app
  consumes them; `RemoteProjectAdapter` maps the package's `RemoteWorkspace` onto the local
  `Project` type and is deliberately not in the package.

**One terminal.** A terminal is a pseudo terminal the app spawns and owns, rendered by libghostty in
the main window's pane. Nothing needs to be installed for it: no iTerm2, no tmux, not even
Ghostty.app. `TerminalStack` builds it at launch and there is nothing to choose. See
`docs/terminal.md`.

`docs/remote-access.md` is the protocol reference for all three repos.

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

`GhosttyKit` is a binary artifact (a 52 MB release asset), and SwiftPM asks the keychain for
credentials for the host serving it. From a non interactive session nobody can answer that prompt,
so `xcodebuild` parks in `BinaryArtifactsManager.download` with near zero CPU and an empty
`SourcePackages/artifacts/libghostty-spm/libghostty/` directory, for as long as you let it. It is
not the "cannot lock ref" failure and clearing caches does not help. `xcodebuild` cannot turn the
keychain lookup off, the `swift` CLI can, and the artifact cache is shared, so warm it once:

```sh
swift package --package-path <a scratch package depending on libghostty-spm> \
  --disable-keychain --disable-netrc resolve
xcodebuild -scheme Wietty -destination 'platform=macOS' -resolvePackageDependencies
```

The download itself takes a few seconds once the keychain is out of the way.

Build and test from the command line:

```sh
xcodebuild -scheme Wietty -destination 'platform=macOS' build
xcodebuild -scheme Wietty -destination 'platform=macOS' test
```

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
