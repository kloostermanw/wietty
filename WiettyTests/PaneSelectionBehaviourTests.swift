import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Which terminal the pane shows, through every path that can move it.
///
/// Written before selection left `GhosttyService`, against the behaviour as it was,
/// so the refactor has something to be measured against rather than described by. The
/// five cases are the ones a user would notice: clicking a row, an agent calling
/// `select_process`, a tap on the iPad, closing the terminal on screen, and closing
/// the last one.
///
/// `displayed` is the one line that knows how the app currently decides what is on
/// screen. Everything else is phrased in terms of what the user sees, so the assertions
/// survive the move.
@MainActor
@Suite struct PaneSelectionBehaviourTests {

    /// A stack and the selection the app wires to it.
    ///
    /// The one place in the suite that knows how the app decides what is on screen.
    /// Before selection left `GhosttyService` this was `service.selected`; it is the
    /// frontend's `TerminalSelection` now, wired exactly as `ContentView` wires it.
    @MainActor
    struct Wired {
        let terminals: TerminalStack
        let selection: TerminalSelection
        let router: PaneRouter
        let store: ProjectStore
        var stack: GhosttyStack { terminals.ghostty }
        var displayed: String? { selection.current }
    }

    private func wired(_ host: FakeSurfaceHost = FakeSurfaceHost()) -> Wired {
        let terminals = TerminalStack(ghosttyHost: host, helperPath: "/usr/bin/true")
        let selection = TerminalSelection()
        let router = PaneRouter()
        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 config: WiettyConfigFile.temporary(), service: terminals.service)
        // The app's own wiring, not a copy of it. Driving the real thing is the point:
        // these three connections used to be made inside a view's task, where nothing
        // could reach them.
        TerminalSelectionWiring.connect(selection: selection, terminals: terminals,
                                        store: store, router: router)
        return Wired(terminals: terminals, selection: selection, router: router, store: store)
    }

    /// What can be read does not depend on what is on screen. A surface can only be
    /// read while it is displayed, so moving the pane used to be a moment the
    /// service had to capture the screen that was leaving. Each terminal's screen
    /// is held by its model now, so both read the same before the move and after
    /// it, whichever one the pane shows.
    @Test func movingThePaneLeavesBothTerminalsReadable() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let service = app.terminals.service
        let first = try await service.open(folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
                                           command: "echo first-$((10+1)); sleep 5", badge: nil).sessionId
        let second = try await service.open(folder: URL(fileURLWithPath: "/tmp"), existingWindowId: nil,
                                            command: "echo second-$((20+2)); sleep 5", badge: nil).sessionId
        #expect(app.displayed == second)
        let models = try #require(app.stack.ghosttyService)
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline,
              models.screenModel(for: first)?.text(maxLines: 5) != "first-11"
                || models.screenModel(for: second)?.text(maxLines: 5) != "second-22" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await service.readOutput(sessionId: first, maxLines: 5) == "first-11")
        #expect(try await service.readOutput(sessionId: second, maxLines: 5) == "second-22")

        _ = try await ask(app, for: first)
        #expect(app.displayed == first)
        #expect(try await service.readOutput(sessionId: first, maxLines: 5) == "first-11")
        #expect(try await service.readOutput(sessionId: second, maxLines: 5) == "second-22")
    }

    private func open(_ app: Wired) async throws -> String {
        try await app.terminals.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                         existingWindowId: nil, command: "sleep 5", badge: nil).sessionId
    }

    /// Asking for a row, as a click, `select_process` and an iPad tap all do. The
    /// store raises the request; this is the service half plus the frontend honouring
    /// it, which is what those three share.
    private func ask(_ app: Wired, for session: String) async throws -> FocusResult {
        let result = try await app.terminals.service.probe(sessionId: session)
        app.selection.show(session)
        return result
    }

    /// Opening a terminal puts it on screen. Every other case below starts from this.
    @Test func openingATerminalShowsIt() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        #expect(app.displayed == first)
        let second = try await open(app)
        #expect(app.displayed == second)
    }

    /// Case 1: a local row click. `ProjectStore.activateThrowing` is what a click on a
    /// sidebar row calls, and the row it names ends up on screen.
    @Test func clickingALocalRowShowsThatTerminal() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        let second = try await open(app)
        #expect(app.displayed == second)

        // Focus is the narrow call underneath the click: it is what moves the pane.
        let result = try await ask(app, for: first)
        #expect(result.found)
        #expect(app.displayed == first)
    }

    /// Case 2: an agent calling `select_process`, which reaches the same `focus`.
    @Test func selectProcessShowsThatTerminal() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        _ = try await open(app)
        _ = try await ask(app, for: first)
        #expect(app.displayed == first)
    }

    /// Case 3: a tap on the iPad. `RemoteServer.activateOutcome` calls
    /// `ProjectStore.activateThrowing`, which reaches the same `focus`, and the
    /// serving Mac's own pane moves with it. `docs/remote-access.md` calls that the
    /// accepted price of one implementation of activation rather than two.
    @Test func aRemoteActivateShowsThatTerminalOnTheServingMac() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        _ = try await open(app)
        _ = try await ask(app, for: first)
        #expect(app.displayed == first)
    }

    /// Case 4: closing the terminal on screen hands the pane to one that remains,
    /// rather than leaving it empty with terminals still open.
    @Test func closingTheDisplayedTerminalHandsThePaneOn() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        let second = try await open(app)
        #expect(app.displayed == second)

        try await app.terminals.service.close(sessionId: second)
        #expect(app.displayed == first)
    }

    /// Case 5: closing the last one empties the pane.
    @Test func closingTheLastTerminalEmptiesThePane() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let only = try await open(app)
        #expect(app.displayed == only)

        try await app.terminals.service.close(sessionId: only)
        #expect(app.displayed == nil)
    }

    /// Showing a local terminal uncovers the pane.
    ///
    /// The connection this asserts is the one that used to be made inside a view's
    /// task, where no test could reach it: settings, a process log or a remote session
    /// sits in front of the terminal until a local one is shown, and then it goes.
    @Test func showingALocalTerminalUncoversWhateverWasInFrontOfThePane() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        let second = try await open(app)

        app.router.show(.settings)
        #expect(app.router.override == .settings)

        _ = try await ask(app, for: first)
        #expect(app.displayed == first)
        #expect(app.router.override == nil)
        _ = second
    }

    /// Emptying the pane leaves an override alone: there is no local terminal to
    /// uncover it for, which is the rule `localSelectionChanged` encodes.
    @Test func emptyingThePaneLeavesAnOverrideInPlace() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let only = try await open(app)
        app.router.show(.settings)

        try await app.terminals.service.close(sessionId: only)
        #expect(app.displayed == nil)
        #expect(app.router.override == .settings)
    }

    /// Closing a terminal that is not the one on screen leaves the pane alone.
    @Test func closingAnUndisplayedTerminalLeavesThePaneAlone() async throws {
        let app = wired()
        defer { app.stack.ghosttyService?.closeAll() }
        let first = try await open(app)
        let second = try await open(app)
        #expect(app.displayed == second)

        try await app.terminals.service.close(sessionId: first)
        #expect(app.displayed == second)
    }
}

/// That the store raises the request the pane moves on.
///
/// The suite above covers the service half and the frontend honouring it. This covers
/// the half between them: a row being asked for, which is what a sidebar click, an
/// agent's `select_process` and an iPad's activate all reach.
@MainActor
@Suite struct ShowTerminalRequestTests {

    /// A store over a real service, with one workspace and two terminals open, wired
    /// to a selection the way the app wires it.
    private func fixture() async throws -> (store: ProjectStore, selection: TerminalSelection,
                                            stack: GhosttyStack, router: PaneRouter,
                                            sessions: [String]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let terminals = TerminalStack(ghosttyHost: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 config: WiettyConfigFile.temporary(), service: terminals.service)
        let selection = TerminalSelection()
        let router = PaneRouter()
        TerminalSelectionWiring.connect(selection: selection, terminals: terminals,
                                        store: store, router: router)
        let stack = terminals.ghostty

        store.addProject(url: folder)
        let project = store.projects[0]
        await store.openTerminal(for: project)
        await store.openTerminal(for: store.projects[0])
        let sessions = store.projects[0].terminals.map(\.sessionId)
        return (store, selection, stack, router, sessions)
    }

    /// Case 2, end to end: `MCPToolRouter.selectProcess` calls `store.focus`, and the
    /// pane ends up on that row.
    @Test func storeFocusPutsTheRowOnScreen() async throws {
        let f = try await fixture()
        defer { f.stack.ghosttyService?.closeAll() }
        #expect(f.sessions.count == 2)
        #expect(f.selection.current == f.sessions[1])

        _ = try await f.store.focus(sessionId: f.sessions[0])
        #expect(f.selection.current == f.sessions[0])
    }

    /// Cases 1 and 3, end to end: a sidebar click and a remote activate both call
    /// `activateThrowing`, and the pane ends up on that row.
    @Test func activatingALiveRowPutsItOnScreen() async throws {
        let f = try await fixture()
        defer { f.stack.ghosttyService?.closeAll() }
        let project = f.store.projects[0]
        #expect(f.selection.current == f.sessions[1])

        try await f.store.activateThrowing(project.terminals[0], in: project)
        #expect(f.selection.current == f.sessions[0])
    }
}
