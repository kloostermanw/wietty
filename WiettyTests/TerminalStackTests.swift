import Testing
import Foundation
@testable import Wietty

/// The composition root, which no longer chooses anything: there is one terminal
/// and the app owns it.
@MainActor
@Suite struct TerminalStackTests {
    @Test func theStackIsTheInternalTerminal() {
        let stack = TerminalStack(ghosttyHost: FakeSurfaceHost())
        defer { stack.ghostty.ghosttyService?.closeAll() }
        #expect(stack.streamer is PaneStreamHub)
        #expect(stack.streamer as AnyObject === stack.ghostty.hub as AnyObject)
    }

    /// The three protocol shaped pieces are the ghostty stack's own, not rebuilt
    /// beside it. Two hubs would mean a viewer reading a stream nothing writes to.
    @Test func theStackHandsOnTheGhosttyStacksPieces() {
        let stack = TerminalStack(ghosttyHost: FakeSurfaceHost())
        defer { stack.ghostty.ghosttyService?.closeAll() }
        #expect(stack.service as AnyObject === stack.ghostty.service as AnyObject)
        #expect(stack.monitor as AnyObject === stack.ghostty.monitor as AnyObject)
    }

    /// A stack that could not be built still exists, so the app launches and can
    /// explain itself rather than failing at every call site. Only libghostty and
    /// the bundled helper can answer this question, and with no substrate left to
    /// fall back to, the message is all the user gets.
    @Test func setupErrorComesFromTheGhosttyStack() {
        let stack = TerminalStack(ghosttyHost: FakeSurfaceHost(), helperPath: nil)
        defer { stack.ghostty.ghosttyService?.closeAll() }
        #expect(stack.setupError == TerminalError.ghosttyHelperMissing.errorDescription)
        #expect(stack.setupError == stack.ghostty.setupError)
    }

    /// The other half: a working stack reports nothing, so the error above is the
    /// injected failure rather than something this branch always says.
    @Test func aWorkingStackReportsNoSetupError() {
        let stack = TerminalStack(ghosttyHost: FakeSurfaceHost(), helperPath: "/usr/bin/true")
        defer { stack.ghostty.ghosttyService?.closeAll() }
        #expect(stack.setupError == nil)
    }
}
