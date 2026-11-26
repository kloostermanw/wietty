import Testing
@testable import Wietty

/// The order of what quitting does. The observer itself (`willTerminate`) is not
/// posted here: the test host is the app, and the notification would tear its own
/// terminals down.
@MainActor
@Suite struct TerminalQuitTeardownTests {
    /// The remote panes are closed before the stack is shut down, so their viewer
    /// surfaces are destroyed while the surface host is whole.
    @Test func theRemotePanesCloseBeforeTheStackShutsDown() {
        var calls: [String] = []
        TerminalQuitTeardown.run(closeRemotePanes: { calls.append("remotePanes") },
                                 shutDownStack: { calls.append("stack") })
        #expect(calls == ["remotePanes", "stack"])
    }
}
