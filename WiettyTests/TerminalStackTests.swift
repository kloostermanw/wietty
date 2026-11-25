import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The composition root, which no longer chooses anything: there is one terminal
/// and the app owns it.
@MainActor
@Suite struct TerminalStackTests {
    @Test func theStackIsTheInternalTerminal() {
        let stack = TerminalStack.testing(host: FakeSurfaceHost())
        defer { stack.ghostty.shutDown() }
        #expect(stack.streamer is PaneStreamHub)
        #expect(stack.streamer as AnyObject === stack.ghostty.hub as AnyObject)
    }

    /// The three protocol shaped pieces are the ghostty stack's own, not rebuilt
    /// beside it. Two hubs would mean a viewer reading a stream nothing writes to.
    @Test func theStackHandsOnTheGhosttyStacksPieces() {
        let stack = TerminalStack.testing(host: FakeSurfaceHost())
        defer { stack.ghostty.shutDown() }
        #expect(stack.service as AnyObject === stack.ghostty.service as AnyObject)
        #expect(stack.monitor as AnyObject === stack.ghostty.monitor as AnyObject)
    }

    /// A stack that could not be built still exists, so the app launches and can
    /// explain itself rather than failing at every call site. Only libghostty and
    /// the bundled helper can answer this question, and with no substrate left to
    /// fall back to, the message is all the user gets.
    @Test func setupErrorComesFromTheGhosttyStack() {
        let stack = TerminalStack(ghosttyHost: FakeSurfaceHost(), helperPath: nil)
        defer { stack.ghostty.shutDown() }
        #expect(stack.setupError == TerminalError.ghosttyHelperMissing.errorDescription)
        #expect(stack.setupError == stack.ghostty.setupError)
    }

    /// The helper the surfaces run is the app's to find and check, so a missing one
    /// is a startup error raised here, with the same text as ever, and every terminal
    /// action throws it. A path to a file that is not executable is missing too.
    @Test func aMissingHelperIsAStartupError() async {
        let notExecutable = TestScratch.root.appendingPathComponent("wietty-pty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: notExecutable.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: notExecutable) }
        for helper in [nil, notExecutable.path] {
            let stack = TerminalStack.testing(host: FakeSurfaceHost(), helperPath: helper)
            #expect(stack.setupError == TerminalError.ghosttyHelperMissing.errorDescription)
            #expect(stack.service is UnavailableTerminalService)
            await #expect(throws: TerminalError.ghosttyHelperMissing) {
                _ = try await stack.service.open(folder: URL(fileURLWithPath: "/tmp"),
                                                 existingWindowId: nil, command: nil, badge: nil)
            }
        }
    }

    /// The launch sweeps what a dead run left in the temp directory and spares what
    /// may be in use: an `ipx-` socket of an older build is removed once it is an
    /// hour old and kept before that, since its name carries no owner.
    @Test func theLaunchSweepsStaleSockets() throws {
        let directory = NSTemporaryDirectory()
        let tag = UInt32.random(in: 0..<0xFFFFFF)
        let fresh = directory + "ipx-fresh\(tag).sock"
        let abandoned = directory + "ipx-old\(tag).sock"
        try Data().write(to: URL(fileURLWithPath: fresh))
        try Data().write(to: URL(fileURLWithPath: abandoned))
        defer {
            unlink(fresh)
            unlink(abandoned)
        }
        let old = Date(timeIntervalSinceNow: -LocalSocketPaths.staleAge - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: abandoned)

        let stack = TerminalStack.testing(host: FakeSurfaceHost())
        defer { stack.ghostty.shutDown() }

        #expect(FileManager.default.fileExists(atPath: fresh))
        #expect(FileManager.default.fileExists(atPath: abandoned) == false)
    }

    /// The other half: a working stack reports nothing, so the error above is the
    /// injected failure rather than something this branch always says.
    @Test func aWorkingStackReportsNoSetupError() {
        let stack = TerminalStack.testing(host: FakeSurfaceHost())
        defer { stack.ghostty.shutDown() }
        #expect(stack.setupError == nil)
    }
}
