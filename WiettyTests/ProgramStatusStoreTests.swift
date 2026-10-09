import Testing
import Foundation
@testable import Wietty

/// A clock the test moves by hand, for the banner rate limit.
@MainActor private final class ManualClock {
    var now = ContinuousClock.now
    func advance(by duration: Duration) { now += duration }
}

/// What the store asked to be posted.
@MainActor private final class Posted {
    var statuses: [ProgramStatusRecord] = []
    var notifications: [String] = []
}

/// What `ProjectStore` does with the program status a terminal reports: what the
/// row shows, how long it shows it, and when it becomes a banner.
@MainActor
@Suite struct ProgramStatusStoreTests {
    @MainActor private struct Fixture {
        let store: ProjectStore
        let clock: ManualClock
        let posted: Posted
        var ref: TerminalRef { store.projects[0].terminals[0] }
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func fixture(source: NotificationSource = .desktopNotifications,
                         defaults: UserDefaults? = nil) async -> Fixture {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
                        TerminalHandle(sessionId: "sess-B", windowId: "win-1")]
        let clock = ManualClock()
        let store = ProjectStore(defaults: defaults ?? makeDefaults(), service: fake, now: { clock.now })
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("proj")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.addProject(url: folder)
        await store.openClaude(for: store.projects[0])
        store.notificationSource = source
        let posted = Posted()
        store.onProgramStatus = { _, _, record in posted.statuses.append(record) }
        store.onNotification = { _, _, _, body in posted.notifications.append(body) }
        return Fixture(store: store, clock: clock, posted: posted)
    }

    private func report(_ state: ProgramStatusState, id: String? = nil, msg: String? = nil,
                        session: String = "sess-A") -> MonitorEvent {
        .programStatus(sessionId: session, .report(.set(id: id, ProgramStatusRecord(state: state, msg: msg))))
    }

    // MARK: - What the row shows

    @Test func aReportShowsOnItsRow() async {
        let f = await fixture()
        f.store.handle(report(.working, msg: "Reading files"))
        #expect(f.store.programStatusSummary(for: f.ref) == ProgramStatusRecord(state: .working, msg: "Reading files"))
    }

    @Test func aReportForAnUntrackedSessionChangesNothing() async {
        let f = await fixture()
        f.store.handle(report(.blocked, session: "elsewhere"))
        #expect(f.store.programStatusSummary(for: f.ref) == nil)
        #expect(f.store.programStatus.isEmpty)
    }

    @Test func aShellPromptEndsWorkingAndBlockedButNotDone() async {
        let f = await fixture()
        f.store.handle(report(.working))
        f.store.handle(report(.done, id: "task"))
        f.store.handle(.programStatus(sessionId: "sess-A", .promptStart))
        #expect(f.store.programStatusSummary(for: f.ref)?.state == .done)
    }

    @Test func aFullResetRemovesEveryRecord() async {
        let f = await fixture()
        f.store.handle(report(.error))
        f.store.handle(.programStatus(sessionId: "sess-A", .fullReset))
        #expect(f.store.programStatusSummary(for: f.ref) == nil)
        #expect(f.store.programStatus[f.ref.id] == nil)
    }

    /// The process the terminal is attached to is the shell, which outlives the
    /// program. The shell coming back to the foreground is the program exiting,
    /// which section 5 says ends its live records; without this a program that died
    /// without clearing them would say "working" forever.
    @Test func theShellReturningToTheForegroundEndsTheProgramsLiveRecords() async {
        let f = await fixture()
        f.store.handle(report(.working))
        f.store.handle(report(.error, id: "lint"))
        f.store.handle(.job(sessionId: "sess-A", jobName: "2.1.295"))
        #expect(f.store.programStatusSummary(for: f.ref)?.state == .error)
        f.store.handle(report(.blocked, id: "ask"))
        f.store.handle(.job(sessionId: "sess-A", jobName: "zsh"))
        #expect(f.store.programStatusSummary(for: f.ref)?.state == .error)
    }

    @Test func theTerminalExitingKeepsOnlyDoneAndError() async {
        let f = await fixture()
        f.store.handle(report(.idle))
        f.store.handle(report(.done, id: "build"))
        f.store.handle(.terminated(sessionId: "sess-A"))
        #expect(f.store.programStatusSummary(for: f.ref)?.state == .done)
    }

    @Test func visitingTheRowAcknowledgesDoneAndError() async {
        let f = await fixture()
        f.store.handle(report(.done))
        f.store.handle(report(.idle, id: "x"))
        await f.store.activate(f.ref, in: f.store.projects[0])
        #expect(f.store.programStatusSummary(for: f.ref)?.state == .idle)
    }

    @Test func visitingTheRowLeavesAProgramThatIsStillWaiting() async {
        let f = await fixture()
        f.store.handle(report(.blocked))
        await f.store.activate(f.ref, in: f.store.projects[0])
        #expect(f.store.programStatusSummary(for: f.ref)?.state == .blocked)
    }

    @Test func typingIntoTheTerminalAcknowledgesDoneAndError() async {
        let f = await fixture()
        f.store.handle(report(.error))
        f.store.clearAttention(sessionId: "sess-A")
        #expect(f.store.programStatusSummary(for: f.ref) == nil)
    }

    @Test func focusingTheSessionAcknowledgesDoneAndError() async throws {
        let f = await fixture()
        f.store.handle(report(.done))
        try await f.store.focus(sessionId: "sess-A")
        #expect(f.store.programStatusSummary(for: f.ref) == nil)
    }

    @Test func removingTheRowForgetsItsStatus() async {
        let f = await fixture()
        let ref = f.ref
        f.store.handle(report(.blocked))
        f.store.removeTerminal(ref, in: f.store.projects[0])
        #expect(f.store.programStatus[ref.id] == nil)
    }

    /// A restart is a new process in the same row, so nothing the old one said
    /// about itself still holds.
    @Test func restartingTheRowStartsWithNoStatus() async throws {
        let f = await fixture()
        f.store.handle(report(.error))
        _ = try await f.store.restart(sessionId: "sess-A")
        #expect(f.store.programStatusSummary(for: f.ref) == nil)
    }

    // MARK: - Banners

    @Test func withDesktopNotificationsAsTheSourceAStatusPostsNothing() async {
        let f = await fixture(source: .desktopNotifications)
        f.store.handle(report(.blocked, msg: "Approve?"))
        f.store.handle(report(.done))
        #expect(f.posted.statuses.isEmpty)
        #expect(!f.store.attention.contains(f.ref.id))
    }

    @Test func withProgramStatusAsTheSourceEnteringBlockedPostsAndRaisesAttention() async {
        let f = await fixture(source: .programStatus)
        f.store.handle(report(.working))
        f.store.handle(report(.blocked, msg: "Approve?"))
        #expect(f.posted.statuses == [ProgramStatusRecord(state: .blocked, msg: "Approve?")])
        #expect(f.store.attention.contains(f.ref.id))
    }

    @Test func doneAndErrorPostButWorkingAndIdleDoNot() async {
        let f = await fixture(source: .programStatus)
        f.store.handle(report(.working))
        f.store.handle(report(.idle))
        #expect(f.posted.statuses.isEmpty)
        f.store.handle(report(.done))
        f.clock.advance(by: .seconds(10))
        f.store.handle(report(.error))
        #expect(f.posted.statuses.map(\.state) == [.done, .error])
    }

    @Test func stayingInAStateIsNotANewBanner() async {
        let f = await fixture(source: .programStatus)
        f.store.handle(report(.blocked, msg: "first"))
        f.clock.advance(by: .seconds(10))
        f.store.handle(report(.blocked, msg: "second"))
        #expect(f.posted.statuses.map(\.msg) == ["first"])
    }

    /// A program can change state as fast as it likes, and section 8 asks for the
    /// effects a person notices to be rate limited.
    @Test func aSecondBannerInsideTheRateLimitIsHeldBack() async {
        let f = await fixture(source: .programStatus)
        f.store.handle(report(.blocked))
        f.store.handle(report(.working))
        f.clock.advance(by: .seconds(1))
        f.store.handle(report(.done))
        #expect(f.posted.statuses.map(\.state) == [.blocked])
        f.store.handle(report(.working))
        f.clock.advance(by: .seconds(2))
        f.store.handle(report(.error))
        #expect(f.posted.statuses.map(\.state) == [.blocked, .error])
    }

    @Test func aBannerFollowsTheSummaryNotTheRecordThatChanged() async {
        // A child finishing while another child is blocked changes nothing the row
        // shows, so it is not news.
        let f = await fixture(source: .programStatus)
        f.store.handle(report(.blocked, id: "a"))
        f.clock.advance(by: .seconds(10))
        f.store.handle(report(.done, id: "b"))
        #expect(f.posted.statuses.map(\.state) == [.blocked])
    }

    @Test func desktopNotificationsFromATerminalThatReportsStatusAreDropped() async {
        let f = await fixture(source: .programStatus)
        f.store.handle(report(.working))
        f.store.handle(.notification(sessionId: "sess-A", title: "Claude Code", body: "Waiting for input"))
        #expect(f.posted.notifications.isEmpty)
        #expect(!f.store.attention.contains(f.ref.id))
    }

    @Test func aTerminalThatNeverReportedStatusKeepsItsDesktopNotifications() async {
        let f = await fixture(source: .programStatus)
        f.store.handle(.notification(sessionId: "sess-A", title: "", body: "Backup finished"))
        #expect(f.posted.notifications == ["Backup finished"])
    }

    @Test func withDesktopNotificationsAsTheSourceTheyAreNeverDropped() async {
        let f = await fixture(source: .desktopNotifications)
        f.store.handle(report(.working))
        f.store.handle(.notification(sessionId: "sess-A", title: "", body: "Waiting for input"))
        #expect(f.posted.notifications == ["Waiting for input"])
    }

    // MARK: - The setting

    @Test func theSourceDefaultsToDesktopNotifications() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        #expect(store.notificationSource == .desktopNotifications)
    }

    @Test func theSourcePersists() {
        let defaults = makeDefaults()
        let first = ProjectStore(defaults: defaults, service: FakeTerminalService())
        first.notificationSource = .programStatus
        #expect(ProjectStore(defaults: defaults, service: FakeTerminalService()).notificationSource == .programStatus)
    }

    @Test func anUnreadableStoredSourceFallsBackToDesktopNotifications() {
        #expect(NotificationSource(stored: "osc-7501") == .programStatus)
        #expect(NotificationSource(stored: "osc-9-777") == .desktopNotifications)
        #expect(NotificationSource(stored: "something-newer") == .desktopNotifications)
        #expect(NotificationSource(stored: "") == .desktopNotifications)
    }
}
