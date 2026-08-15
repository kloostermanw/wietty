import Testing
import Foundation
import HTTPTypes
@testable import Wietty

/// `POST /api/terminals/{ref_id}/activate`, the served side of a click on a
/// remote row.
///
/// The route exists because nothing else in the protocol can revive a dead row.
/// `restart` and `close` are keyed by session id, and the rows that print
/// `[session ended]` in a viewer's pane are precisely the ones with no usable
/// session id: a row imported from a workspace config and never opened carries an
/// empty one, and a row whose serving Mac was relaunched carries one that names
/// nothing. `run_state` cannot be used to spot them either, since it reports the
/// row's foreground job and answers "running" whenever no job has been heard of.
@Suite @MainActor struct RemoteActivateTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("proj")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storeWithOneTerminal(_ fake: FakeTerminalService) async -> ProjectStore {
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder())
        await store.openTerminal(for: store.projects[0])
        return store
    }

    @Test func anUnknownRowIsNotFound() async {
        let store = await storeWithOneTerminal(FakeTerminalService())
        #expect(await RemoteServer.activateOutcome(store: store,
                                                   refId: UUID().uuidString) == .notFound)
    }

    /// A `tid` that is not a UUID is the viewer asking wrongly rather than asking
    /// about something gone, and the two are worth telling apart: no snapshot this
    /// Mac ever sent could have named it.
    @Test func aRefIdThatIsNotAUUIDIsARejectedRequest() async {
        let store = await storeWithOneTerminal(FakeTerminalService())
        #expect(await RemoteServer.activateOutcome(store: store, refId: "sess-A") == .badRequest)
        #expect(await RemoteServer.activateOutcome(store: store, refId: nil) == .badRequest)
    }

    /// The bug from the issue: the row has no session to attach to, so the route
    /// opens one and answers with the id of what it opened, rather than handing
    /// back the dead id the viewer already had.
    @Test func aRowWithNoSessionGetsOneOpenedAndReportsItsNewId() async {
        let fake = FakeTerminalService()
        // `focus` answering not-found is what a session that is gone looks like
        // from the store's side.
        fake.focusResult = FocusResult(found: false, jobName: nil)
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
                        TerminalHandle(sessionId: "sess-B", windowId: "win-1")]
        let store = await storeWithOneTerminal(fake)
        let refId = store.projects[0].terminals[0].id

        let outcome = await RemoteServer.activateOutcome(store: store, refId: refId.uuidString)

        #expect(fake.openCalls.count == 2)
        #expect(store.projects[0].terminals[0].sessionId == "sess-B")
        guard case let .ok(.object(members)) = outcome else {
            Issue.record("expected a terminal object, got \(outcome)")
            return
        }
        #expect(members["session_id"] == .string("sess-B"))
        #expect(members["id"] == .string(refId.uuidString))
    }

    /// A live row is left alone. Opening a second session for it would strand the
    /// one the viewer can already see.
    @Test func aLiveRowKeepsItsSession() async {
        let fake = FakeTerminalService()
        fake.focusResult = FocusResult(found: true, jobName: nil)
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = await storeWithOneTerminal(fake)
        let refId = store.projects[0].terminals[0].id

        let outcome = await RemoteServer.activateOutcome(store: store, refId: refId.uuidString)

        #expect(fake.openCalls.count == 1)
        guard case let .ok(.object(members)) = outcome else {
            Issue.record("expected a terminal object, got \(outcome)")
            return
        }
        #expect(members["session_id"] == .string("sess-A"))
    }

    /// The path the route exists for, failing: the session is gone and its
    /// replacement cannot be opened.
    ///
    /// `openErrorToThrow` rather than `errorToThrow`, which fails every call and so
    /// cannot reach this at all: `focus` is asked first, and a fake that refuses it
    /// too ends the activation before a reopen is ever attempted.
    @Test func aRowWhoseReopenFailsCarriesTheReason() async {
        let fake = FakeTerminalService()
        fake.focusResult = FocusResult(found: false, jobName: nil)
        let store = await storeWithOneTerminal(fake)
        let refId = store.projects[0].terminals[0].id
        // Only now, so the row exists before opening starts failing.
        fake.openErrorToThrow = .failed("no terminal")

        let outcome = await RemoteServer.activateOutcome(store: store, refId: refId.uuidString)

        #expect(outcome == .failed("no terminal"))
        // The row is left as it was found, and the dead session has already been
        // given up: a revival that fails after `discard` has spent the old screen,
        // which is why the reason has to reach the viewer rather than a bare 500.
        #expect(store.projects[0].terminals[0].sessionId == "sess-1")
        #expect(fake.discardCalls == ["sess-1"])
    }

    /// A store that refuses before any reopen is attempted reports its reason the
    /// same way, rather than being reported as a row that has no session.
    @Test func aRowWhoseFocusFailsCarriesTheReason() async {
        let fake = FakeTerminalService()
        let store = await storeWithOneTerminal(fake)
        let refId = store.projects[0].terminals[0].id
        fake.errorToThrow = .failed("terminal is not answering")

        let outcome = await RemoteServer.activateOutcome(store: store, refId: refId.uuidString)

        #expect(outcome == .failed("terminal is not answering"))
    }

    /// What the viewer is told, which `docs/remote-access.md` states as a promise.
    /// A failure is this Mac's, and must not be answerable as the viewer's snapshot
    /// being stale: those two ask the person on the other end to do different things.
    @Test func eachOutcomeHasItsOwnStatus() {
        #expect(RemoteServer.ActivateOutcome.badRequest.status == .badRequest)
        #expect(RemoteServer.ActivateOutcome.notFound.status == .notFound)
        #expect(RemoteServer.ActivateOutcome.failed("boom").status == .internalServerError)
        #expect(RemoteServer.ActivateOutcome.noSession.status == .internalServerError)
        #expect(RemoteServer.ActivateOutcome.ok(.object([:])).status == .ok)
    }

    /// The reason travels, so a viewer holding a 500 can say what went wrong
    /// without anyone walking over to the serving Mac to read its log.
    @Test func aFailureAnswersWithItsReason() {
        #expect(RemoteServer.ActivateOutcome.failed("no terminal").body
                == JSONValue.object(["error": .string("no terminal")]))
        #expect(RemoteServer.ActivateOutcome.noSession.body != nil)
        #expect(RemoteServer.ActivateOutcome.notFound.body == nil)
    }
}

/// The viewing side of the same click: what `ContentView` says when an activation
/// answers no session id.
@Suite @MainActor struct RemoteActivationFeedbackTests {
    @Test func aNamedSessionSaysNothing() {
        #expect(ContentView.remoteActivationFailureMessage(sessionId: "sess-A",
                                                           lastActionError: nil) == nil)
    }

    /// A refused action already writes the connection's red caption, and an alert
    /// on top of it would say the same thing twice.
    @Test func aReportedFailureIsLeftToTheCaption() {
        #expect(ContentView.remoteActivationFailureMessage(sessionId: nil,
                                                           lastActionError: "Action failed (500).") == nil)
    }

    /// The case this exists for. `RemoteWorkspaceStore.activate` clears
    /// `lastActionError` on any 2xx and then answers nil for a body it could not
    /// read, so a serving Mac that says 200 and names no session used to leave a
    /// click with no pane, no caption and nothing said anywhere.
    @Test func aSuccessfulReplyNamingNoSessionIsReported() {
        let message = ContentView.remoteActivationFailureMessage(sessionId: nil,
                                                                 lastActionError: nil)
        #expect(message != nil)
    }
}
