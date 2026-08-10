# Bells, and the notifications they post

A terminal that rings the bell (`BEL`, `0x07`) lights a 🔔 on its row in the
sidebar and posts a macOS notification. Tapping the notification shows that
terminal. This document covers where a bell comes from, what decides whether it is
worth interrupting for, and the two places the answer differs.

## Where a bell comes from

Nothing here detects bells. A local one arrives as `MonitorEvent.bell(sessionId:)`
from libghostty's own action callback, `GHOSTTY_ACTION_RING_BELL`, in
`GhosttySurfaceHost`. `PaneStreamHub` also counts `0x07` in a session's byte stream,
for the viewers it serves, and that is deliberately not the same code: telling a real
bell from a `0x07` inside an OSC string needs the escape state only whoever parses
the stream has.

## One notification per flag, not per bell

`ProjectStore.handle` inserts the row's id into `attention` on a bell, and the
notification is posted only when that insert is what turned the flag on. Every bell
after that, until the row is visited, posts nothing.

This is the whole noise control, and it matters because plain terminals ring for
ordinary reasons: `zsh` and `bash` ring on an ambiguous tab completion. Without the
rule, holding tab down would post a notification per keystroke. With it, a beeping
completion is one notification, and visiting the row re-arms the next one.

The identifier is derived from the target and is therefore stable per terminal, so
even a bell that does slip through twice replaces its own notification instead of
stacking a second copy.

## What is suppressed

`BellAlert.shouldPost` drops exactly one case: this app is frontmost **and** its
pane is already showing the terminal that rang. Anything else is posted, including
a bell that arrives while Wietty is frontmost but showing a different terminal,
because with the sidebar in front of you a bell from another workspace's agent is
the thing you most want to be told.

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
good. It is asked for once, and a denial is not re-litigated on every ring.

If permission is denied, or the notification centre refuses the bundle, nothing is
posted and nothing is said. The 🔔 in the sidebar still works, and an alert about a
failed notification would be an interruption complaining about an interruption.

One thing worth knowing when testing this by hand: `UNUserNotificationCenter`
refuses an app bundle run from a scratch directory outright
(`UNErrorDomain Code=1`, "Notifications are not allowed for this application"),
whatever its signature. A build under DerivedData or an app in `/Applications` is
fine. The app's ad-hoc signature is not the problem, and no entitlement is needed.

## What is not covered by tests

The decisions all are: the target's round trip, the banner's text, the suppression
rule, the watcher's diff including reconnects, the store firing once per flag, and
the delegate selectors existing (that last one guards the async delegate methods
still being exposed to Objective C, which nothing else would catch).

Actually posting, granting permission, and what a tap does to the window need a
running app and a person, and a remote bell needs a second Mac.
