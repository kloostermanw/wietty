import Testing
import Foundation
@testable import Wietty

/// What the main window's pane shows, and therefore which sidebar row is marked.
///
/// The rule is the whole of the feature: the pane is one view position and the
/// sidebar lists local terminals, remote ones, and processes, so everything about
/// "which one is on screen" is decided here. The renderers behind it, and the
/// attach itself, need a LAN peer and are verified by hand.
@Suite struct PaneSelectionTests {
    private let connection = UUID()
    private let otherConnection = UUID()
    private let project = UUID()
    private let otherProject = UUID()

    private func log(_ name: String, isTest: Bool = false, in id: UUID? = nil) -> ProcessLogRef {
        ProcessLogRef(projectId: id ?? project, name: name, isTest: isTest)
    }

    @Test func nothingSelectedIsNone() {
        #expect(PaneSelection.resolve(local: nil, override: nil) == .none)
    }

    @Test func aLocalSelectionAloneIsLocal() {
        #expect(PaneSelection.resolve(local: "gt:1", override: nil) == .local("gt:1"))
    }

    @Test func aRemoteOverrideAloneIsRemote() {
        let session = RemoteSessionRef(connectionId: connection, sessionId: "%3")
        #expect(PaneSelection.resolve(local: nil, override: .remote(session)) == .remote(session))
    }

    @Test func aLogOverrideAloneIsAProcessLog() {
        #expect(PaneSelection.resolve(local: nil, override: .log(log("npm")))
                == .processLog(log("npm")))
    }

    @Test func aSettingsOverrideAloneIsSettings() {
        #expect(PaneSelection.resolve(local: nil, override: .settings) == .settings)
    }

    /// The precedence, and the reason the local selection is left alone rather than
    /// cleared: the pane holds one thing, so whatever was picked covers the local
    /// terminal instead of replacing it.
    @Test func anOverrideCoversALocalSelection() {
        let session = RemoteSessionRef(connectionId: connection, sessionId: "%3")
        #expect(PaneSelection.resolve(local: "gt:1", override: .remote(session)) == .remote(session))
        #expect(PaneSelection.resolve(local: "gt:1", override: .log(log("npm")))
                == .processLog(log("npm")))
        #expect(PaneSelection.resolve(local: "gt:1", override: .settings) == .settings)
    }

    /// Settings covers the terminal rather than replacing it, which is the whole of
    /// its dismissal: clearing the override is what clicking a terminal row already
    /// does, and the terminal comes back with no close button anywhere.
    @Test func clearingASettingsOverrideUncoversTheLocalSelection() {
        var override: PaneOverride? = .settings
        override = nil
        #expect(PaneSelection.resolve(local: "gt:1", override: override) == .local("gt:1"))
    }

    /// Settings is a third thing that can cover the terminal and it is in the same
    /// value as the other two, so opening it while a log is on screen replaces the
    /// log rather than leaving both set.
    @Test func settingsReplacesWhateverElseCoveredTheTerminal() {
        var override: PaneOverride? = .log(log("npm"))
        override = .settings
        #expect(PaneSelection.resolve(local: "gt:1", override: override) == .settings)
    }

    /// The other half of covering: clearing the override puts the local terminal
    /// back rather than emptying the pane, which is what makes leaving a remote
    /// session or a log return to where the user was.
    @Test func clearingTheOverrideUncoversTheLocalSelection() {
        #expect(PaneSelection.resolve(local: "gt:1", override: nil) == .local("gt:1"))
    }

    /// Two things cover the local terminal and they cannot both be on screen, which
    /// is why they are one value rather than two. Picking a log after a remote
    /// session replaces it, and nothing has to remember to clear the other.
    @Test func onlyOneThingCoversTheLocalTerminal() {
        let session = RemoteSessionRef(connectionId: connection, sessionId: "%3")
        var override: PaneOverride? = .remote(session)
        override = .log(log("npm"))
        #expect(PaneSelection.resolve(local: "gt:1", override: override)
                == .processLog(log("npm")))
    }

    /// The pane draws local and nothing-selected through one view, so both must
    /// answer this and everything that covers a local session must hide it.
    @Test func onlyALocalSelectionHasALocalSession() {
        #expect(PaneSelection.local("gt:1").localSession == "gt:1")
        #expect(PaneSelection.none.localSession == nil)
        #expect(PaneSelection.remote(RemoteSessionRef(connectionId: connection,
                                                      sessionId: "%3")).localSession == nil)
        #expect(PaneSelection.processLog(log("npm")).localSession == nil)
        #expect(PaneSelection.settings.localSession == nil)
    }

    @Test func aLocalRowIsMarkedOnlyWhenItIsTheOneOnScreen() {
        let selection = PaneSelection.local("gt:1")
        #expect(selection.selects(localSession: "gt:1"))
        #expect(!selection.selects(localSession: "gt:2"))
        #expect(!PaneSelection.none.selects(localSession: "gt:1"))
    }

    /// A remote selection must leave every local row unmarked, or the sidebar would
    /// claim two things are on screen at once.
    @Test func aRemoteSelectionMarksNoLocalRow() {
        let selection = PaneSelection.remote(RemoteSessionRef(connectionId: connection,
                                                             sessionId: "gt:1"))
        #expect(!selection.selects(localSession: "gt:1"))
    }

    @Test func aRemoteRowIsMarkedOnlyWhenItIsTheOneOnScreen() {
        let selection = PaneSelection.remote(RemoteSessionRef(connectionId: connection,
                                                             sessionId: "%3"))
        #expect(selection.selects(remoteSession: "%3", on: connection))
        #expect(!selection.selects(remoteSession: "%4", on: connection))
        #expect(!PaneSelection.none.selects(remoteSession: "%3", on: connection))
    }

    /// The connection is part of the match. Session ids are minted per Mac, so two
    /// connections routinely hand out the same one, and matching on the id alone
    /// would mark a row on every connection at once.
    @Test func aRemoteRowOnAnotherConnectionIsNotMarked() {
        let selection = PaneSelection.remote(RemoteSessionRef(connectionId: connection,
                                                             sessionId: "%3"))
        #expect(!selection.selects(remoteSession: "%3", on: otherConnection))
    }

    /// A local selection must leave every remote row unmarked, for the same reason
    /// as the reverse.
    @Test func aLocalSelectionMarksNoRemoteRow() {
        #expect(!PaneSelection.local("%3").selects(remoteSession: "%3", on: connection))
    }

    @Test func aProcessRowIsMarkedOnlyWhenItsLogIsOnScreen() {
        let selection = PaneSelection.processLog(log("npm"))
        #expect(selection.selects(processLog: log("npm")))
        #expect(!selection.selects(processLog: log("api")))
        #expect(!PaneSelection.none.selects(processLog: log("npm")))
    }

    /// The workspace is part of the match. Two workspaces routinely declare a
    /// process under the same name, and matching on the name alone would mark a row
    /// in every one of them at once.
    @Test func aProcessRowInAnotherWorkspaceIsNotMarked() {
        let selection = PaneSelection.processLog(log("npm"))
        #expect(!selection.selects(processLog: log("npm", in: otherProject)))
    }

    /// Processes and tests are separate namespaces that may share a name, so a test
    /// called `npm` is not the process called `npm`.
    @Test func aTestIsNotTheProcessOfTheSameName() {
        let selection = PaneSelection.processLog(log("npm", isTest: true))
        #expect(selection.selects(processLog: log("npm", isTest: true)))
        #expect(!selection.selects(processLog: log("npm")))
    }

    /// A log on screen must leave every terminal row unmarked, and a terminal on
    /// screen must leave every process row unmarked.
    @Test func aLogAndATerminalNeverMarkEachOthersRows() {
        #expect(!PaneSelection.processLog(log("npm")).selects(localSession: "gt:1"))
        #expect(!PaneSelection.processLog(log("npm")).selects(remoteSession: "%3", on: connection))
        #expect(!PaneSelection.local("gt:1").selects(processLog: log("npm")))
    }

    /// Settings belongs to no workspace, so it must leave every row in the sidebar
    /// unmarked. Without this the sidebar would keep claiming a terminal is on
    /// screen while the panel is covering it.
    @Test func settingsMarksNoRow() {
        let selection = PaneSelection.settings
        #expect(!selection.selects(localSession: "gt:1"))
        #expect(!selection.selects(remoteSession: "%3", on: connection))
        #expect(!selection.selects(processLog: log("npm")))
    }

    /// The gear is marked while the panel is on screen, the same way a row is marked
    /// while its terminal is, and nothing else marks it.
    @Test func onlySettingsMarksTheGear() {
        #expect(PaneSelection.settings.showsSettings)
        #expect(!PaneSelection.none.showsSettings)
        #expect(!PaneSelection.local("gt:1").showsSettings)
        #expect(!PaneSelection.processLog(log("npm")).showsSettings)
        #expect(!PaneSelection.remote(RemoteSessionRef(connectionId: connection,
                                                       sessionId: "%3")).showsSettings)
    }

    /// The selection key deliberately excludes the row's label. A remote row's
    /// label follows the foreground job on the other Mac and changes while it is on
    /// screen, and a selection keyed on it would unmark the row mid-command.
    @Test func aRenamedRowIsStillTheSameSession() {
        let before = RemoteSessionRef(connectionId: connection, sessionId: "%3")
        let after = RemoteSessionRef(connectionId: connection, sessionId: "%3")
        #expect(before == after)
    }
}
