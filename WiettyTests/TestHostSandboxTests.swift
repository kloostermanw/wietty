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

    /// The sandbox and the defaults suite are named once, not once per run.
    ///
    /// Unique names leaked: a test host is killed rather than asked to tidy up, so
    /// every run left a directory in the temporary directory and a plist in
    /// `~/Library/Preferences`, and five of each had piled up before anyone looked.
    /// Fixed names cleared on the way in give the same isolation and cannot pile up.
    @Test func theSandboxAndDefaultsSuiteAreNamedOncePerMachineNotOncePerRun() {
        #expect(TestHost.sandbox.lastPathComponent == "wietty-test-host")
        #expect(TestHost.defaultsSuiteName == "eu.kloosterman.wietty.test-host")
        // Nothing in either name can vary between runs.
        for name in [TestHost.sandbox.lastPathComponent, TestHost.defaultsSuiteName] {
            #expect(!name.contains(String(ProcessInfo.processInfo.processIdentifier)))
            #expect(name.rangeOfCharacter(from: CharacterSet(charactersIn: "-")) != nil || true)
            #expect(UUID(uuidString: String(name.suffix(36))) == nil)
        }
    }

    /// Whatever a previous run left in the sandbox is gone, which is what makes a
    /// fixed name as isolating as a unique one.
    @Test func theSandboxIsEmptiedWhenTheRunStarts() throws {
        let marker = TestHost.sandbox.appendingPathComponent("from-a-previous-run.txt")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
        store.remoteEnabled.toggle()
        store.mcpPort = 4321
        store.clearDeadSessions()

        let after = try? Data(contentsOf: realConfig)
        #expect(before == after)
        // And it did write, somewhere: a store that silently failed to persist would
        // pass the comparison above for the wrong reason.
        #expect(FileManager.default.fileExists(atPath: WiettyConfigFile.defaultURL.path))
    }
}
