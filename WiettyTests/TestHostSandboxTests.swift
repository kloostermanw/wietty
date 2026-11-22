import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The suite must not touch the developer's own settings.
///
/// It runs inside the real app (`TEST_HOST` is `Wietty.app`), so launching it runs
/// `WiettyApp.init` and builds a store with default arguments. Before `TestHost`,
/// that store read and rewrote `~/.config/wietty/config`: every run stripped the
/// session ids of the user's live terminals, and one run during issue #84 deleted
/// their sidebar colours, bell sound and sidebar width outright.
@MainActor
@Suite struct TestHostSandboxTests {
    private var realConfig: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/wietty/config")
    }

    @Test func theSuiteKnowsItIsATestHost() {
        #expect(TestHost.isActive)
    }

    /// Asserted before anything writes, so a regression here is caught without the
    /// run having already damaged the file this is about.
    @Test func theDefaultConfigPathIsInTheRunsSandbox() {
        #expect(WiettyConfigFile.defaultURL != realConfig)
        #expect(WiettyConfigFile.defaultURL.path.hasPrefix(TestHost.sandbox.path))
    }

    /// The other two files the app writes into `~/.config/wietty/`, for the same
    /// reason: the host builds the colour settings and the prompt template store
    /// over their default paths.
    @Test func theOtherConfigPathsAreInTheRunsSandbox() {
        #expect(GhosttyOverrideFile.defaultURL.path.hasPrefix(TestHost.sandbox.path))
        #expect(PromptTemplateFile.defaultURL.path.hasPrefix(TestHost.sandbox.path))
    }

    @Test func theDefaultDefaultsAreNotTheAppsOwnDomain() {
        #expect(TestHost.defaults !== UserDefaults.standard)
    }

    /// The real proof: a store built the way the host app builds one, made to write,
    /// leaves the user's file untouched. Compares the bytes rather than a timestamp,
    /// because a write that produced identical content would still be a write that
    /// reached the wrong file.
    @Test func aStoreWithDefaultArgumentsNeverWritesTheRealFile() throws {
        let before = try? Data(contentsOf: realConfig)

        let store = ProjectStore(service: FakeTerminalService())
        store.showWorkspaceBadge = !store.showWorkspaceBadge
        store.mcpPort = 4321
        store.clearDeadSessions()

        let after = try? Data(contentsOf: realConfig)
        #expect(before == after)
        // And it did write, somewhere: a store that silently failed to persist would
        // pass the comparison above for the wrong reason.
        #expect(FileManager.default.fileExists(atPath: WiettyConfigFile.defaultURL.path))
    }
}
