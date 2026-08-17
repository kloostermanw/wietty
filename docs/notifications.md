# What a terminal notifies you about

A terminal asks for your attention in two ways, and this app treats them as two
things. Ringing the bell (`BEL`, `0x07`) is one byte that says only that it rang.
Asking for a desktop notification (`OSC 9` or `OSC 777`) carries a title and a body
a program chose to send, which is how coding agents announce that they are waiting
on input. Either one lights a 🔔 on the terminal's row in the sidebar and posts a
macOS notification whose tap shows that terminal.

This document covers where each comes from, what decides whether it is worth
interrupting for, and every place the two answers differ.

## Where they come from

Nothing here detects either. Both arrive from libghostty's own action callback in
`GhosttySurfaceHost`: `GHOSTTY_ACTION_RING_BELL` becomes
`MonitorEvent.bell(sessionId:)` and `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` becomes
`MonitorEvent.notification(sessionId:title:body:)`. A notification with no body
becomes a bell there, because a banner with nothing in it says less than no banner,
but something did happen on that terminal and the row should still be marked for it.
An empty body counts as no body: libghostty passes an empty string for an `OSC 9;`
carrying no payload. One with no title is kept, because `OSC 9;text` supplies only a
body.

Something has to send one before any of this runs, and what decides that is the environment the
shell was spawned with. A program picks between the bell, `OSC 9` and `OSC 777` by reading
`TERM_PROGRAM`, so a terminal that leaves it unset is told nothing by an agent that would otherwise
have announced itself. `RawPTY.spawn` sets it to `Wietty` (`docs/terminal.md`, under "Spawning the
shell"). Before it did, this whole path was correct and idle.

One thing that decides whether the action arrives at all is libghostty's rather than
this app's: it gates `OSC 9` and `OSC 777` behind its own `desktop-notifications`
setting, and `GhosttySurfaceHost` calls `ghostty_config_load_default_files`, so a
user who turned that off in their own Ghostty config gets no action here and
therefore no banner. The bell is not gated that way.

That gate is on the Notifications tab, because it used to be invisible: turned off,
a program asking for a notification is answered by nothing at all, and the Settings
window said as much about it as the terminal did. `DesktopNotificationSetting` writes
`~/.config/wietty/ghostty.cfg` and `GhosttySurfaceHost` loads that file after the
user's own config, so the toggle wins without Wietty ever editing a file Ghostty.app
reads. The file does not exist until the toggle is first used, which is what makes
deferring to the user's own config the default rather than something to ask for.
There is no control for going back to it, because there is nothing to go back from
that deleting the file does not undo.

The same file also carries the terminal's colours, which the General tab writes
through `GhosttyColorSettings` (see terminal.md). `GhosttyOverrideFile` manages both,
line by line, so a colour and this toggle coexist without disturbing each other.

It is a file because libghostty has no setter: handing it another file is the only
way to change a value at all. That also decides how the tab reads. The resolved value
comes back through `ghostty_config_get` rather than from the file, so the switch shows
what the terminal is running on, and says so when the two configs disagree. Changing
it calls `ghostty_app_update_config` and `ghostty_surface_update_config`, so terminals
that are already open take the new value.

The default is on, measured against the linked libghostty rather than assumed, so the
overwhelmingly common case of no config file at all notifies normally.

`PaneStreamHub` also counts `0x07` in a session's byte stream, for the viewers it
serves, and that is deliberately not the same code: telling a real bell from a
`0x07` inside an OSC string needs the escape state only whoever parses the stream
has. Nothing in the byte stream path parses `OSC 9`.

Remote sessions have bells only. The LAN remote protocol carries `needs_attention`
and no message that could hold a title, so a notification sent on a connected Mac
reaches this one as a bell, and giving it words is a `wietty-shared` change.

## Both raise the flag; only one of them is rationed

`ProjectStore.handle` inserts the row's id into `attention` for either event, so
the 🔔 means "this terminal wants you" whichever way it said so, and visiting the
row withdraws the banner through one path.

What is posted differs:

- **A bell is posted only when the insert is what turned the flag on.** Every bell
  after that, until the row is visited, posts nothing. This is the whole noise
  control, and it matters because plain terminals ring for ordinary reasons: `zsh`
  and `bash` ring on an ambiguous tab completion. Without the rule, holding tab down
  would post a notification per keystroke.
- **A notification is posted every time.** An `OSC 9` is a program choosing to send
  words, not a side effect of typing, and an agent that says "waiting for input" and
  then "build failed" has said two things. Swallowing the second because the row had
  not been visited would lose the one that matters.

Nothing stacks either way. The identifier is derived from the target and is
therefore stable per terminal, so a newer banner replaces that terminal's older one
rather than adding to it. A message that arrives after a bell replaces the bell's
banner, which is the right way round: it says more.

The two rules meet in one place worth knowing. A bell that follows a notification is
silent, because the flag is already up and the bell has nothing to add.

## What the banner says

A bell's banner reads "Rang the bell." under `workspace / terminal`, because that is
all a bell carries; anything more specific would be a guess about a program this app
received one byte from.

A message uses the words that were sent: the program's own title on top, the
terminal underneath, and its body as the body. With two agents running,
"Waiting for input" on its own does not say which one is waiting, which is why the
terminal is still there. `OSC 9;text` sends no title, so in that case the terminal
moves up into the title and the subtitle is left out rather than blank.

`BellNotification` builds both, so what a banner says is asserted in tests rather
than only visible when something rings.

## What is suppressed

`BellAlert.shouldPost` drops exactly one case, and it is the same for both: this app
is frontmost **and** its pane is already showing the terminal that rang. Anything
else is posted, including a bell that arrives while Wietty is frontmost but showing
a different terminal, because with the sidebar in front of you a bell from another
workspace's agent is the thing you most want to be told.

The suppression is possible because the terminal is inside this window: what is on
screen is a fact the app owns, so `terminalIsOnScreen` can answer it.

The banner is shown even while Wietty is frontmost, which macOS would otherwise
suppress. That is the `willPresent` delegate callback returning `[.banner, .sound]`,
and it is deliberate: being frontmost is not the same as watching the terminal that
rang, and the narrower rule above is applied before anything is posted.

## Local bells and remote bells arrive differently

A local bell is an event, so it happens once by construction.

A remote bell is not. The LAN remote protocol has no bell message: the server
pushes the complete workspace list on every change and a ringing session is one
with `needs_attention` set (see `remote-access.md`). `RemoteBellWatcher` therefore
keeps the set of flagged sessions per connection and reports the difference, and two
rules in it are load bearing:

- **The first snapshot from a connection is adopted in silence.** Connecting to a
  Mac whose agent has been waiting for an hour must not announce it as news, and on
  launch every connection delivers exactly such a snapshot.
- **What is known survives a drop.** `RemoteWorkspaceStore` keeps its last snapshot
  through a disconnect and replaces it on reconnect, so treating a reconnect as a
  first snapshot would re-announce every waiting agent on every network blip.
  Keeping the set means a reconnect is silent while a bell that rang while the link
  was down is still reported once it is back.

A connection removed and added again is forgotten deliberately, so re-adding a Mac
does not announce its backlog.

`RemoteBellObserver` is what feeds the watcher, and it subscribes to each store's
published `workspaces` with Combine rather than from a view. That is a requirement,
not a preference: the sidebar is a `LazyVStack`, so a remote section scrolled out of
view is never built, and notifications are precisely the feature that has to work
while nobody is looking.

## Tapping one

`BellTarget` is carried in the notification's `userInfo` as strings, because the
system hands it back after a relaunch and it has to survive being read by a later
build. Anything that does not decode is ignored: a wrong guess would activate the
wrong terminal.

A local target is the **row's id**, not its session id. The row id survives a
restart that mints a new session, so a tap still reaches the right row, and it is
also the key `attention` uses, so withdrawing a notification needs no lookup that a
removed row could fail. A remote target is the connection plus the session id, the
same pair the pane uses, because two Macs routinely hand out the same session id.

The tap reopens the main window through `openWindow` (so it works even if that
window was closed), brings the app forward, and then does exactly what clicking the
row does: `ProjectStore.activate` for a local session, which selects it into the
pane, and the same pane for a remote one.

`SystemNotificationSink` holds one tap that arrives before anyone is listening.
That is required rather than defensive: tapping a notification can launch the app,
and the system delivers that tap as soon as a delegate exists, which is during
launch and therefore before `ContentView` has run its `task`. Without the buffer the
one tap that matters most, the one that started the app, is the one that is lost.

## Withdrawing

Visiting a row takes its notification back out of Notification Center, so bells
already dealt with do not pile up. The hook is a `didSet` on `attention` rather than
a call in `activate`, because a dozen paths clear a flag (activating, closing,
restarting, removing a row, removing a workspace) and the next one added would
forget to call it. Remote notifications are withdrawn the same way, from the
watcher's `cleared` set.

Withdrawing never asks for permission. Asking there would mean the first thing
someone who has never had a bell sees is a permission prompt caused by clicking a
row.

## Permission

Requested on the first bell, not at launch: a prompt in front of someone who has
not rung a bell is a prompt about nothing, and a denial there costs the feature for
good. It is asked for once, and a denial is not re-litigated on every ring. The
Notifications tab in Settings is the other way to trigger it, deliberately, since
pressing a button that says "Allow notifications…" is a moment that explains itself
at least as well as the first bell does.

If permission is denied, or the notification centre refuses the bundle, nothing is
posted and nothing is said on the bell path. The 🔔 in the sidebar still works, and
an alert about a failed notification would be an interruption complaining about an
interruption. The Settings tab is where both do get said, because a button pressed
to find out whether the path works answers the opposite question when it fails
silently.

A denial and a refusal are kept apart, which is what `requestAuthorization`
throwing is for. A denial is the user's answer, so the tab points at System
Settings. A refusal means the request never reached them, so the tab says macOS
turned it down and what usually causes that. Reporting a refusal as a denial sends
someone to a switch in System Settings that will not be there.

`BellNotifier.permission()` reads the state afresh every time rather than from its
own cache, and writes what it read back into that cache. Permission can be granted
or revoked in System Settings while the app runs, so a tab showing a remembered
answer would be the one place that is wrong about it, and a `granted` of false
decided at the first bell would otherwise outlive the permission being granted from
the tab.

## The app has to be signed

`UNUserNotificationCenter` refuses an app bundle macOS does not accept, and it
refuses it in about a millisecond, with `UNErrorDomain Code=1` ("Notifications are
not allowed for this application") and without ever showing a prompt. Nothing about
that is visible from the outside: the request comes back, nobody was asked, and the
state is still "not asked yet".

The bundle has to carry a real signature for that not to happen. Ad hoc is enough
and no developer account or entitlement is involved, but "unsigned" is not enough,
and `CODE_SIGNING_ALLOWED: NO` in `project.yml` means unsigned: it leaves the
Mach-O with a linker signature and the *bundle* with none, so `codesign -dv`
reports `Identifier=Wietty` rather than the bundle id, `Info.plist=not bound` and
`Sealed Resources=none`. Every shipped build was in that state until this was
fixed, so notifications could never have worked for anyone, and the silent failure
path meant nothing said so. A correctly signed build reports
`Identifier=eu.kloosterman.wietty`, an Info.plist entry count, and sealed
resources, and `scripts/make-dmg.sh` now refuses to package anything else.

Where the bundle sits is not what the centre objects to, and running from a scratch
directory is not what makes the difference. Only the signature is.

The Test button and the permission button both report this rather than swallowing
it, which is what makes it findable at all.

A Focus mode is the other reason a banner does not appear while permission says
"Allowed", and no API tells the app that happened, so the Notifications tab says it
in words instead.

## The sound

`ProjectStore.bellSound` is one `BellSound`: silence, the system alert sound
(`Default`, and what this app played before the setting existed), or one of the
sounds in `/System/Library/Sounds` by name. It is persisted under
`wietty.bellSound`, applies to the next notification with no restart, and rides on
the `BellNotification` value rather than being read inside the sink, so what a
banner will play is something a test can see.

Anything unreadable in that preference (a value written by a later build, a sound a
macOS release removed) falls back to the default sound rather than to silence: a
value this build cannot read is not a reason to stop making a noise the user asked
for. A stored sound that is no longer installed is still offered by the picker, so
the control names what is missing instead of appearing blank.

## What is not covered by tests

The decisions all are: the target's round trip, the banner's text for both kinds,
the suppression rule, the watcher's diff including reconnects, the store's two
different posting rules, the sound preference's round trip and fallback, what the
settings tab asks of the notifier (and that reading permission never prompts), and
the delegate selectors existing (that last one guards the async delegate methods
still being exposed to Objective C, which nothing else would catch).

Actually posting, granting permission, and what a tap does to the window need a
running app and a person, and a remote bell needs a second Mac. Two things in
particular are worth a manual pass: that a real
`printf '\033]9;Waiting for input\a'` in a pane produces the banner, and that a
named sound is actually audible on that banner.

The second one is not settled, and the tab cannot settle it. `NSSound(named:)`
searches `/System/Library/Sounds`, which is where the picker's list comes from.
`UNNotificationSound(named:)` does not: it resolves a name against the app bundle
and the container's `Library/Sounds`. It is also non failable, and `add` does not
validate the sound, so a name it cannot resolve costs nothing visible. The banner
arrives with the default sound and every check in the app still reports success.

So the two buttons check different paths deliberately. "Test" beside the picker
previews the file through `NSSound`. "Send test notification" is the one that goes
through `UNNotificationSound`, and it is the one to listen to: press it with a named
sound chosen and compare what you hear against the preview. If they differ, the
named sounds need installing where `UNNotificationSound` looks rather than being
offered from `/System/Library/Sounds`.
