# Releasing

Releases are driven by [`git-release`](https://github.com/kloostermanw/git-release),
configured in `.gitrelease`. Run it from a clean `develop` branch:

```sh
git-release
```

It prompts for the new tag. It auto-suggests a patch bump of the last tag; type
the tag you actually want (the version scheme is `vMAJOR.MINOR.PATCH`).

## What happens automatically

1. `git-release` creates a `release/<tag>` branch off `develop`.
2. **cmd1** runs `scripts/set-version.sh --release <tag>`, which rewrites
   `MARKETING_VERSION` in `project.yml` to the tag (with the leading `v`
   stripped). `git-release` commits `project.yml` on the release branch, so the
   version is baked into the tagged commit.
3. `git-release` merges the release branch into `main`, creates the annotated
   tag, and pushes `main` (with tags) to origin. It merges `main` back into
   `develop` and pushes that too.
4. **cmd3** runs `scripts/publish-release.sh --release <tag>`, which:
   - creates the GitHub release for the pushed tag (`--generate-notes` fills in
     the release body, which the in-app updater shows),
   - runs `scripts/make-dmg.sh` to build a Release `.dmg`,
   - uploads it as `Wietty.<tag>.dmg`.

## Version syncing and the in-app updater

`MARKETING_VERSION` is the app's `CFBundleShortVersionString`, which
`AppVersion.current` reads. The in-app update check (`UpdateService`) compares a
release's tag against that value, so keeping them in sync (step 2) is what makes
"a newer version is available" correct for the next release.

## Re-running after a failure

If cmd3 fails after the tag is already pushed (for example a build error),
re-run the publish step by hand once fixed. It is idempotent: it reuses an
existing GitHub release and re-uploads the asset with `--clobber`.

```sh
scripts/publish-release.sh --release <tag>
```

## Release notes for a behavior changing release

`gh release create --generate-notes` (step 4 above) writes the release body from merged PR titles
alone, which the in-app updater then shows verbatim. That is enough for routine changes, but a
release that changes user facing behavior in a way no PR title conveys needs a hand written
addition. Edit the release body after cmd3 runs, with `gh release edit <tag>` or the GitHub web UI,
and prepend the explanation above the generated "What's Changed" list.

The note below is that addition for 2.0, which removes both iTerm2 substrates. It leads with what
changes for someone who never touched the setting, because that is everyone by default.

> **Terminals now run inside Wietty.** iTerm2 and the optional tmux layer are gone, and with them
> the "Terminals run on" setting. Every terminal and agent is a pseudo terminal Wietty owns,
> rendered by Ghostty in the pane beside the sidebar, and nothing has to be installed for it: no
> iTerm2, no tmux, not even Ghostty.app. If you have a Ghostty configuration file, its font, theme,
> cursor, and keybindings are used.
>
> Your workspaces, rows, processes and remote connections are untouched. Terminals opened by an
> earlier version are not carried over, because a running iTerm2 session or tmux pane cannot be
> handed to the new terminal: each row opens a fresh terminal the first time you click it. That is a
> reset, not lost data.
>
> Terminals do not survive quitting the app. A row whose terminal is gone reopens on the next click.
> Two windows are also gone: process logs and remote sessions are drawn in the same pane, so the app
> is one window.
