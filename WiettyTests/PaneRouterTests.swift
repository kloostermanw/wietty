import Testing
import Foundation
@testable import Wietty

/// What uncovers the local terminal.
///
/// These rules used to live inside `ContentView`'s `.task` closure and its
/// `onChange`, where nothing could assert them, and one of them was wrong: leaving
/// the settings panel depended on the local selection *changing*, which activating
/// the terminal the panel is covering does not do. `GhosttyService.select` returns
/// early when the session is already selected, so its callback never fires. On this
/// side of the move each rule is a method, and the two that a user's way out depends
/// on are the first two tests below.
@MainActor
@Suite struct PaneRouterTests {
    private let connection = UUID()
    private let otherConnection = UUID()
    private let project = UUID()

    /// One workspace's id for the whole suite, so two calls with the same name are the
    /// same log. A fresh `UUID` per call would make every comparison fail.
    private func log(_ name: String) -> ProcessLogRef {
        ProcessLogRef(projectId: project, name: name)
    }

    private func remote(on id: UUID) -> RemoteSessionRef {
        RemoteSessionRef(connectionId: id, sessionId: "%3")
    }

    @Test func aNewRouterCoversNothing() {
        #expect(PaneRouter().override == nil)
    }

    /// The gear toggles. Without this the panel has no exit at all when no local
    /// terminal is selected, which is a fresh install and every moment after the last
    /// terminal is closed: there is no row to activate, and the gear would only
    /// re-assign `.settings`.
    @Test func theGearClosesTheSettingsItOpened() {
        let router = PaneRouter()
        router.toggleSettings()
        #expect(router.override == .settings)
        router.toggleSettings()
        #expect(router.override == nil)
    }

    /// Toggling from something else opens settings rather than closing that thing,
    /// because the gear is not a general "clear the pane" button.
    @Test func theGearOpensSettingsOverAnythingElse() {
        let router = PaneRouter()
        router.show(.log(log("npm")))
        router.toggleSettings()
        #expect(router.override == .settings)
    }

    /// Activating a terminal row takes the pane back even when the selection does not
    /// change, which is the case that matters: the row a user clicks to leave the
    /// panel is the row the panel is covering, and that terminal is already selected.
    @Test func activatingATerminalUncoversItWithoutASelectionChange() {
        let router = PaneRouter()
        router.show(.settings)
        router.localTerminalActivated()
        #expect(router.override == nil)
    }

    @Test func activatingATerminalAlsoLeavesALogAndARemoteSession() {
        let router = PaneRouter()
        router.show(.log(log("npm")))
        router.localTerminalActivated()
        #expect(router.override == nil)
        router.show(.remote(remote(on: connection)))
        router.localTerminalActivated()
        #expect(router.override == nil)
    }

    /// A selection made anywhere else (another row, the MCP server, a remote client)
    /// takes the pane too.
    @Test func aLocalSelectionElsewhereUncoversThePane() {
        let router = PaneRouter()
        router.show(.settings)
        router.localSelectionChanged(to: "gt:1")
        #expect(router.override == nil)
    }

    /// Deliberately not on a nil selection. The service selects nil when the last
    /// local terminal closes, and blanking a panel someone is reading would be a bug
    /// rather than an intent.
    @Test func losingTheLastTerminalLeavesThePaneAlone() {
        let router = PaneRouter()
        router.show(.settings)
        router.localSelectionChanged(to: nil)
        #expect(router.override == .settings)
    }

    /// A connection removed while its session is on screen takes the session with it,
    /// because the rows went with the connection and the pane would otherwise sit on a
    /// placeholder with nothing left to click out of it.
    @Test func removingAConnectionUncoversItsSession() {
        let router = PaneRouter()
        router.show(.remote(remote(on: connection)))
        router.connectionsChanged(to: [otherConnection])
        #expect(router.override == nil)
    }

    @Test func aConnectionStillPresentKeepsItsSession() {
        let router = PaneRouter()
        router.show(.remote(remote(on: connection)))
        router.connectionsChanged(to: [otherConnection, connection])
        #expect(router.override == .remote(remote(on: connection)))
    }

    /// The settings panel is where connections are deleted now, so it has to survive
    /// the deletion. Clearing any override on a connection change would make the panel
    /// vanish under the cursor of the person using it.
    @Test func deletingAConnectionLeavesTheSettingsPanelUp() {
        let router = PaneRouter()
        router.show(.settings)
        router.connectionsChanged(to: [])
        #expect(router.override == .settings)
    }

    @Test func deletingAConnectionLeavesALogUp() {
        let router = PaneRouter()
        router.show(.log(log("npm")))
        router.connectionsChanged(to: [])
        #expect(router.override == .log(log("npm")))
    }
}
