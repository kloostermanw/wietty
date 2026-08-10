import Testing
import Foundation
import ItermplexShared
@testable import Wietty

/// What a bell notification carries, and what tapping it routes to.
@Suite struct BellTargetTests {
    private let connection = UUID()

    @Test func aLocalTargetSurvivesTheRoundTrip() throws {
        let refId = UUID()
        let target = BellTarget.local(refId: refId)
        #expect(BellTarget(userInfo: target.userInfo) == target)
    }

    @Test func aRemoteTargetSurvivesTheRoundTrip() throws {
        let target = BellTarget.remote(RemoteSessionRef(connectionId: connection, sessionId: "%3"))
        #expect(BellTarget(userInfo: target.userInfo) == target)
    }

    /// The tap arrives from the system, with whatever was written when the
    /// notification was posted, possibly by an older build. Anything that does not
    /// decode has to be ignored rather than guessed at, because guessing means
    /// activating the wrong terminal.
    @Test func nonsenseDecodesToNothing() {
        #expect(BellTarget(userInfo: [:]) == nil)
        #expect(BellTarget(userInfo: ["wietty.bell.kind": "sideways"]) == nil)
        // Local, with no row id.
        #expect(BellTarget(userInfo: ["wietty.bell.kind": "local"]) == nil)
        // Local, with something that is not a uuid.
        #expect(BellTarget(userInfo: ["wietty.bell.kind": "local",
                                      "wietty.bell.ref": "not-a-uuid"]) == nil)
        // Remote, missing the connection.
        #expect(BellTarget(userInfo: ["wietty.bell.kind": "remote",
                                      "wietty.bell.session": "%3"]) == nil)
        // Remote, missing the session.
        #expect(BellTarget(userInfo: ["wietty.bell.kind": "remote",
                                      "wietty.bell.connection": connection.uuidString]) == nil)
        // Remote, with an empty session id, which matches no row.
        #expect(BellTarget(userInfo: ["wietty.bell.kind": "remote",
                                      "wietty.bell.connection": connection.uuidString,
                                      "wietty.bell.session": ""]) == nil)
    }

    /// The identifier is what makes a second bell replace the first rather than
    /// stack another copy, so it has to be the same for one terminal and different
    /// for any other.
    @Test func theIdentifierIsStablePerTerminalAndUniqueBetweenThem() {
        let refId = UUID()
        #expect(BellTarget.local(refId: refId).notificationIdentifier
                == BellTarget.local(refId: refId).notificationIdentifier)
        #expect(BellTarget.local(refId: refId).notificationIdentifier
                != BellTarget.local(refId: UUID()).notificationIdentifier)

        let session = RemoteSessionRef(connectionId: connection, sessionId: "%3")
        #expect(BellTarget.remote(session).notificationIdentifier
                == BellTarget.remote(session).notificationIdentifier)
        // The same session id on another Mac is another terminal.
        #expect(BellTarget.remote(session).notificationIdentifier
                != BellTarget.remote(RemoteSessionRef(connectionId: UUID(), sessionId: "%3"))
                    .notificationIdentifier)
    }
}

/// The words in the banner.
@Suite struct BellNotificationContentTests {
    @Test func aLocalBellNamesTheWorkspaceAndTheRow() {
        let refId = UUID()
        let notification = BellNotification.local(workspace: "Wietty",
                                                  label: "Claude Code", refId: refId)
        #expect(notification.title == "Wietty / Claude Code")
        // macOS already puts the app's name above the banner, so nothing here repeats
        // it, and there is no second Mac to name.
        #expect(notification.subtitle == "")
        #expect(!notification.body.isEmpty)
        #expect(notification.target == .local(refId: refId))
        #expect(notification.identifier == BellTarget.local(refId: refId).notificationIdentifier)
    }

    /// A remote bell is otherwise indistinguishable from a local one, and which Mac
    /// rang is the first thing you need.
    @Test func aRemoteBellNamesTheConnectionToo() {
        let session = RemoteSessionRef(connectionId: UUID(), sessionId: "%3")
        let notification = BellNotification.remote(connection: "mac-mini", workspace: "api",
                                                   label: "Claude Code", session: session)
        #expect(notification.title == "api / Claude Code")
        #expect(notification.subtitle == "mac-mini")
        #expect(notification.target == .remote(session))
    }
}

/// Whether a bell is worth interrupting for.
@Suite struct BellAlertTests {
    /// The one case that is suppressed: the app is in front and its pane is already
    /// showing the terminal that rang, so the user is looking at it.
    @Test func aTerminalTheUserIsWatchingIsNotAnnounced() {
        #expect(!BellAlert.shouldPost(appIsFrontmost: true, terminalIsOnScreen: true))
    }

    /// Frontmost is not the same as watched. With the sidebar in front of you, a bell
    /// from another workspace's agent is exactly what you want to be told.
    @Test func everythingElseIsAnnounced() {
        #expect(BellAlert.shouldPost(appIsFrontmost: true, terminalIsOnScreen: false))
        #expect(BellAlert.shouldPost(appIsFrontmost: false, terminalIsOnScreen: true))
        #expect(BellAlert.shouldPost(appIsFrontmost: false, terminalIsOnScreen: false))
    }
}

/// Posting, and the permission it needs.
@MainActor
@Suite struct BellNotifierTests {
    /// Records what a real notification centre would have been asked to do.
    private final class FakeSink: NotificationSink {
        var granted = true
        var authorizationRequests = 0
        var added: [BellNotification] = []
        var withdrawn: [[String]] = []
        var onTap: (@MainActor (BellTarget) -> Void)?

        func requestAuthorization() async -> Bool {
            authorizationRequests += 1
            return granted
        }
        func add(_ notification: BellNotification) { added.append(notification) }
        func removeDelivered(identifiers: [String]) { withdrawn.append(identifiers) }
    }

    private func notification(_ label: String = "Claude Code") -> BellNotification {
        BellNotification.local(workspace: "Wietty", label: label, refId: UUID())
    }

    @Test func anAuthorizedBellIsPosted() async {
        let sink = FakeSink()
        let notifier = BellNotifier(sink: sink)
        let bell = notification()
        await notifier.post(bell)
        #expect(sink.added == [bell])
    }

    /// Denied means silent, forever and without complaint. The 🔔 in the sidebar is
    /// still there, and an alert about a failed notification would be an interruption
    /// complaining about an interruption.
    @Test func aDeniedBellIsDropped() async {
        let sink = FakeSink()
        sink.granted = false
        let notifier = BellNotifier(sink: sink)
        await notifier.post(notification())
        #expect(sink.added.isEmpty)
    }

    /// Permission is asked for once, not once per bell, and a denial is not
    /// re-litigated on every ring.
    @Test func permissionIsAskedForOnce() async {
        let sink = FakeSink()
        let notifier = BellNotifier(sink: sink)
        await notifier.post(notification("one"))
        await notifier.post(notification("two"))
        await notifier.post(notification("three"))
        #expect(sink.authorizationRequests == 1)
        #expect(sink.added.count == 3)
    }

    @Test func aDenialIsNotAskedAgain() async {
        let sink = FakeSink()
        sink.granted = false
        let notifier = BellNotifier(sink: sink)
        await notifier.post(notification("one"))
        await notifier.post(notification("two"))
        #expect(sink.authorizationRequests == 1)
    }

    @Test func withdrawingReachesTheCentre() async {
        let sink = FakeSink()
        let notifier = BellNotifier(sink: sink)
        let bell = notification()
        await notifier.post(bell)
        notifier.withdraw([bell.target])
        #expect(sink.withdrawn == [[bell.identifier]])
    }

    /// Withdrawing must never be what triggers the permission prompt: the first thing
    /// someone who has never had a bell would see is then a request caused by them
    /// clicking a row.
    @Test func withdrawingBeforeAnyBellAsksForNothing() {
        let sink = FakeSink()
        let notifier = BellNotifier(sink: sink)
        notifier.withdraw([.local(refId: UUID())])
        #expect(sink.authorizationRequests == 0)
        #expect(sink.withdrawn.isEmpty)
    }

    @Test func withdrawingNothingDoesNothing() async {
        let sink = FakeSink()
        let notifier = BellNotifier(sink: sink)
        await notifier.post(notification())
        notifier.withdraw([])
        #expect(sink.withdrawn.isEmpty)
    }
}

/// The one thing about the real notification centre adapter that can be asserted
/// without an authorized bundle, and the failure it would otherwise hide.
///
/// `SystemNotificationSink` implements the two delegate callbacks as Swift `async`
/// methods, which only work because Swift emits an Objective C thunk onto the
/// completion handler selectors the framework actually calls. If that ever stops
/// happening, or a signature drifts, nothing fails to compile: the app simply stops
/// being told about taps, and a tapped notification silently does nothing.
@Suite struct SystemNotificationSinkTests {
    @Test func theDelegateSelectorsExist() {
        let selectors = [
            "userNotificationCenter:willPresentNotification:withCompletionHandler:",
            "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"
        ]
        for name in selectors {
            #expect(class_getInstanceMethod(SystemNotificationSink.self, Selector(name)) != nil,
                    "SystemNotificationSink does not answer \(name)")
        }
        // The control, so the two above cannot be passing because every selector
        // answers. This is the third optional method of the same protocol, which is
        // deliberately not implemented: there is no in app settings screen to open.
        #expect(class_getInstanceMethod(
            SystemNotificationSink.self,
            Selector("userNotificationCenter:openSettingsForNotification:")) == nil)
    }
}

/// Turning whole snapshots into bell events.
///
/// The most bug prone part of the feature, because the remote protocol has no bell
/// message: everything here is a difference between two complete workspace lists.
@Suite struct RemoteBellWatcherTests {
    private let connection = UUID()
    private let other = UUID()

    private func ringer(_ sessionId: String, label: String = "Claude Code",
                        workspace: String = "api") -> RemoteRinger {
        RemoteRinger(sessionId: sessionId, label: label, workspace: workspace)
    }

    /// Connecting to a Mac whose agent has been waiting for an hour must not announce
    /// it as news. Every connection delivers such a snapshot on launch.
    @Test func theFirstSnapshotIsAdoptedInSilence() {
        var watcher = RemoteBellWatcher()
        let diff = watcher.diff(connection: connection, flagged: [ringer("%1"), ringer("%2")])
        #expect(diff.isEmpty)
    }

    @Test func aFlagThatTurnsOnIsReported() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        let diff = watcher.diff(connection: connection, flagged: [ringer("%1")])
        #expect(diff.ringing == [ringer("%1")])
        #expect(diff.cleared.isEmpty)
    }

    /// The snapshot is pushed again on every unrelated change (a git status, another
    /// workspace's job), so a flag that is merely still on must not ring again.
    @Test func aFlagThatStaysOnIsNotReportedTwice() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        _ = watcher.diff(connection: connection, flagged: [ringer("%1")])
        let again = watcher.diff(connection: connection, flagged: [ringer("%1")])
        #expect(again.isEmpty)
    }

    @Test func aFlagThatTurnsOffIsReportedAsCleared() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        _ = watcher.diff(connection: connection, flagged: [ringer("%1"), ringer("%2")])
        let diff = watcher.diff(connection: connection, flagged: [ringer("%2")])
        #expect(diff.ringing.isEmpty)
        #expect(diff.cleared == ["%1"])
    }

    /// Cleared and then set again is a new bell: the row was visited on the other Mac
    /// and its agent is asking a second time.
    @Test func aFlagThatComesBackRingsAgain() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        _ = watcher.diff(connection: connection, flagged: [ringer("%1")])
        _ = watcher.diff(connection: connection, flagged: [])
        let diff = watcher.diff(connection: connection, flagged: [ringer("%1")])
        #expect(diff.ringing == [ringer("%1")])
    }

    /// `RemoteWorkspaceStore` keeps its last snapshot through a drop and replaces it
    /// on reconnect, so a reconnect resending the same state must not re-announce
    /// every waiting agent. This is the network blip case.
    @Test func aReconnectResendingTheSameStateIsSilent() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        _ = watcher.diff(connection: connection, flagged: [ringer("%1")])
        // The link drops and comes back, and the first snapshot after it is identical.
        let diff = watcher.diff(connection: connection, flagged: [ringer("%1")])
        #expect(diff.isEmpty)
    }

    /// The other half of that: something that started ringing while the link was down
    /// is still news when it comes back, which is what keeping the set rather than
    /// resetting it buys.
    @Test func aBellRungWhileDisconnectedIsStillReported() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        let diff = watcher.diff(connection: connection, flagged: [ringer("%7")])
        #expect(diff.ringing == [ringer("%7")])
    }

    @Test func connectionsAreTrackedApart() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        _ = watcher.diff(connection: other, flagged: [])
        _ = watcher.diff(connection: connection, flagged: [ringer("%1")])
        // The same session id on the other Mac is a different terminal and still new.
        let diff = watcher.diff(connection: other, flagged: [ringer("%1")])
        #expect(diff.ringing == [ringer("%1")])
    }

    /// A connection removed and added again is a first snapshot again, or re-adding a
    /// Mac would announce its whole backlog.
    @Test func forgettingAConnectionRestoresTheSilentFirstSnapshot() {
        var watcher = RemoteBellWatcher()
        _ = watcher.diff(connection: connection, flagged: [])
        watcher.forget(connection: connection)
        let diff = watcher.diff(connection: connection, flagged: [ringer("%1")])
        #expect(diff.isEmpty)
    }

    /// Reads the wire model, including the workspace name, which the sidebar's
    /// adapter drops.
    @Test func flaggedSessionsAreReadFromTheSnapshot() {
        let workspaces = [
            RemoteWorkspace(id: UUID(), name: "api", sessions: [
                RemoteSession(id: UUID(), sessionId: "%1", label: "Terminal 1",
                              isRunning: true, needsAttention: false),
                RemoteSession(id: UUID(), sessionId: "%2", label: "Claude Code",
                              kind: .claude, isRunning: true, needsAttention: true)
            ]),
            RemoteWorkspace(id: UUID(), name: "web", sessions: [
                RemoteSession(id: UUID(), sessionId: "%3", label: "Claude Code",
                              kind: .claude, isRunning: true, needsAttention: true)
            ])
        ]
        #expect(RemoteBellWatcher.flagged(in: workspaces) == [
            RemoteRinger(sessionId: "%2", label: "Claude Code", workspace: "api"),
            RemoteRinger(sessionId: "%3", label: "Claude Code", workspace: "web")
        ])
    }

    @Test func aSnapshotWithNothingFlaggedIsEmpty() {
        let workspaces = [RemoteWorkspace(id: UUID(), name: "api", sessions: [
            RemoteSession(id: UUID(), sessionId: "%1", label: "Terminal 1",
                          isRunning: true, needsAttention: false)
        ])]
        #expect(RemoteBellWatcher.flagged(in: workspaces).isEmpty)
    }
}

/// The store's two hooks, which are what a local bell and a visited row reach.
@MainActor
@Suite struct BellHookTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.bells.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(_ fake: FakeTerminalService) -> ProjectStore {
        ProjectStore(defaults: makeDefaults(), service: fake)
    }

    @Test func aBellOnATrackedRowFiresOnce() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        var rung: [(String, UUID)] = []
        store.onBell = { project, ref in rung.append((project.name, ref.id)) }

        store.handle(.bell(sessionId: "sess-A"))
        #expect(rung.count == 1)
        #expect(rung.first?.0 == "proj")
        #expect(rung.first?.1 == ref.id)
    }

    /// The rule that makes a beeping tab completion one notification rather than
    /// dozens: a row already asking for attention has nothing new to say.
    @Test func aSecondBellOnTheSameRowIsSilent() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        var count = 0
        store.onBell = { _, _ in count += 1 }
        store.handle(.bell(sessionId: "sess-A"))
        store.handle(.bell(sessionId: "sess-A"))
        store.handle(.bell(sessionId: "sess-A"))
        #expect(count == 1)
    }

    /// And it re-arms once the row has been visited, so the next real bell is
    /// announced.
    @Test func aBellAfterTheRowWasVisitedFiresAgain() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        fake.focusResult = FocusResult(found: true, jobName: "node")
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        var count = 0
        store.onBell = { _, _ in count += 1 }
        store.handle(.bell(sessionId: "sess-A"))
        await store.activate(ref, in: store.projects[0])
        store.handle(.bell(sessionId: "sess-A"))
        #expect(count == 2)
    }

    @Test func aBellForAnUnknownSessionFiresNothing() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        var count = 0
        store.onBell = { _, _ in count += 1 }
        store.handle(.bell(sessionId: "someone-elses-session"))
        #expect(count == 0)
    }

    /// Visiting a row reports its id, which is what withdraws its notification. The
    /// hook is on the attention set itself rather than on `activate`, because a dozen
    /// paths clear a flag and the next one added would forget to call it.
    @Test func clearingAttentionReportsTheRow() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        fake.focusResult = FocusResult(found: true, jobName: "node")
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        var cleared: [Set<UUID>] = []
        store.onAttentionCleared = { cleared.append($0) }

        store.handle(.bell(sessionId: "sess-A"))
        #expect(cleared.isEmpty)
        await store.activate(ref, in: store.projects[0])
        #expect(cleared == [[ref.id]])
    }

    /// Closing a row also clears it, through a different path, which is the point of
    /// putting the hook on the set.
    @Test func closingARowAlsoReportsIt() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        store.handle(.bell(sessionId: "sess-A"))
        var cleared: [Set<UUID>] = []
        store.onAttentionCleared = { cleared.append($0) }
        await store.closeTerminal(ref, in: store.projects[0])
        #expect(cleared == [[ref.id]])
    }

    /// A notification outlives the session it was posted about, so the tap is routed
    /// by row id.
    @Test func aRowIsFoundByItsId() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = makeStore(fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        let found = store.session(withRefId: ref.id)
        #expect(found?.ref.id == ref.id)
        #expect(found?.project.name == "proj")
        #expect(store.session(withRefId: UUID()) == nil)
    }
}
