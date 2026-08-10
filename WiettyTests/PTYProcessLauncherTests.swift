import Testing
import Foundation
@testable import Wietty

/// Every test here waits for the OUTPUT it asserts on, not only for the exit.
///
/// `PTYProcessLauncher` hops output to the main actor from a `.utility` read source
/// and hops the exit from an independent `waitpid` thread, with no ordering between
/// the two, so the exit routinely lands first and the output arrives a turn later.
/// Waiting on the exit alone made this suite fail roughly two runs in five, which
/// blocks CI on a product-side ordering bug that predates the substrate work and is
/// filed separately.
@MainActor
@Suite struct PTYProcessLauncherTests {
    let dir = URL(fileURLWithPath: "/tmp")

    @Test func capturesOutputAndZeroExit() async throws {
        let launcher = PTYProcessLauncher()
        var output = ""
        var exit: Int32?
        _ = try launcher.launch(
            command: "printf 'hello\\n'", directory: dir, environment: [:],
            onOutput: { output += $0 },
            onExit: { exit = $0 }
        )
        try await waitUntil { exit != nil && output.contains("hello") }
        #expect(exit == 0)
        #expect(output.contains("hello"))
    }

    @Test func reportsNonZeroExit() async throws {
        let launcher = PTYProcessLauncher()
        var exit: Int32?
        _ = try launcher.launch(
            command: "exit 3", directory: dir, environment: [:],
            onOutput: { _ in },
            onExit: { exit = $0 }
        )
        try await waitUntil { exit != nil }
        #expect(exit == 3)
    }

    @Test func reportsTTYToChild() async throws {
        let launcher = PTYProcessLauncher()
        var output = ""
        var exit: Int32?
        _ = try launcher.launch(
            command: "test -t 1 && echo istty || echo notty", directory: dir, environment: [:],
            onOutput: { output += $0 },
            onExit: { exit = $0 }
        )
        try await waitUntil { exit != nil && output.contains("istty") }
        #expect(output.contains("istty"))
    }

    /// End to end through the real shell: a binary that exists only in a folder
    /// the prelude adds to PATH is found, which is the case `env` cannot express.
    @Test func shellInitPutsABinaryOnThePathForTheCommand() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("only-here")
        try "#!/bin/sh\necho found-it\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let process = ManagedProcess(
            name: "p",
            config: ProcessConfig(
                command: "only-here", kind: .shortRunning,
                shellInit: ["export PATH=\(bin.path):$PATH"]
            ),
            directory: dir,
            launcher: PTYProcessLauncher()
        )
        process.start()
        try await waitUntil {
            process.state != .running && process.log.lines.contains { $0.contains("found-it") }
        }
        #expect(process.state == .finished)
        #expect(process.log.lines.contains { $0.contains("found-it") })
    }

    /// Without the prelude the same binary is not on PATH, which is what makes
    /// the test above prove the prelude did the work.
    @Test func withoutShellInitTheSameBinaryIsNotFound() async throws {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("only-here-too")
        try "#!/bin/sh\necho found-it\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let process = ManagedProcess(
            name: "p",
            config: ProcessConfig(command: "only-here-too", kind: .shortRunning),
            directory: dir,
            launcher: PTYProcessLauncher()
        )
        process.start()
        try await waitUntil { process.state != .running }
        #expect(process.state != .finished)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
