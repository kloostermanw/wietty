import Testing
import Foundation
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
        #expect(await RemoteServer.activatedTerminalJSON(store: store,
                                                        refId: UUID().uuidString) == nil)
    }

    @Test func aRefIdThatIsNotAUUIDIsNotFound() async {
        let store = await storeWithOneTerminal(FakeTerminalService())
        #expect(await RemoteServer.activatedTerminalJSON(store: store, refId: "sess-A") == nil)
        #expect(await RemoteServer.activatedTerminalJSON(store: store, refId: nil) == nil)
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

        let json = await RemoteServer.activatedTerminalJSON(store: store, refId: refId.uuidString)

        #expect(fake.openCalls.count == 2)
        #expect(store.projects[0].terminals[0].sessionId == "sess-B")
        guard case let .object(members)? = json else {
            Issue.record("expected a terminal object")
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

        let json = await RemoteServer.activatedTerminalJSON(store: store, refId: refId.uuidString)

        #expect(fake.openCalls.count == 1)
        guard case let .object(members)? = json else {
            Issue.record("expected a terminal object")
            return
        }
        #expect(members["session_id"] == .string("sess-A"))
    }

    /// A serving Mac that cannot open a terminal has not activated anything, and
    /// answering 200 with the row's empty session id would send the viewer
    /// straight back to `[session ended]` with nothing said about why.
    @Test func aRowThatCouldNotBeOpenedIsAnError() async {
        let fake = FakeTerminalService()
        fake.focusResult = FocusResult(found: false, jobName: nil)
        let store = await storeWithOneTerminal(fake)
        let refId = store.projects[0].terminals[0].id
        // Only now, so the row exists before every terminal call starts failing.
        fake.errorToThrow = .failed("no terminal")

        #expect(await RemoteServer.activatedTerminalJSON(store: store,
                                                        refId: refId.uuidString) == nil)
    }
}
