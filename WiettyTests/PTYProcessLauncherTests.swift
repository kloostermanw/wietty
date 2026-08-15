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
        let launcher = PTYProcessLauncher(spawnsFromTestHost: true)
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
        let launcher = PTYProcessLauncher(spawnsFromTestHost: true)
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
        let launcher = PTYProcessLauncher(spawnsFromTestHost: true)
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
            launcher: PTYProcessLauncher(spawnsFromTestHost: true)
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
            launcher: PTYProcessLauncher(spawnsFromTestHost: true)
        )
        process.start()
        try await waitUntil { process.state != .running }
        #expect(process.state != .finished)
    }

    /// The default launcher refuses to spawn from a test host, which is what keeps
    /// `ProjectStore`'s default supervisors inert in the suite. A workspace config
    /// carrying `auto_start` was once applied straight through to a real login shell
    /// with the developer's own `HOME`, and the fixture command was `rm -rf ~`.
    @Test func theDefaultLauncherRefusesToSpawnFromATestHost() {
        #expect(PTYProcessLauncher.isRunningInTestHost)
        #expect(throws: ProcessLaunchError.spawnRefusedInTestHost) {
            _ = try PTYProcessLauncher().launch(
                command: "echo this must never run", directory: dir, environment: [:],
                onOutput: { _ in }, onExit: { _ in }
            )
        }
    }

    /// And a store built the way most of the suite builds one launches nothing, even
    /// though its supervisors hold the real launcher by default.
    ///
    /// The assertions are all synchronous, and deliberately so. Checking that the
    /// command's side effect never happened cannot fail: `posix_spawn` returns as
    /// soon as the child exists, and the child still has to load a login shell
    /// before it runs anything, so the side effect is always absent this early
    /// whether or not the guard is there. What separates the two is the state the
    /// refusal leaves behind: `launchMain` marks the process `.failed(-1)` the
    /// moment `launch` throws, and a spawn that went through would leave it
    /// `.running` instead.
    @Test func aDefaultStoreLaunchesNothingFromAnAutoStartConfig() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let marker = workspace.appendingPathComponent("spawned")
        _ = try ConfigFile.write(
            WorkspaceConfig(
                name: nil, agents: [], terminals: [],
                processes: ["boot": ProcessConfig(command: "touch \(marker.path)", autoStart: true)]
            ),
            in: workspace
        )

        let store = ProjectStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
                                 service: FakeTerminalService())
        store.addProject(url: workspace)
        store.approvePendingConfig()

        // Without these the test would also pass if the file stopped being
        // detected or approving became a no-op, which is to say if nothing ever
        // reached the launcher in the first place.
        let project = try #require(store.projects.first)
        #expect(project.configProcesses?["boot"]?.autoStart == true)
        let process = try #require(store.processes.process(projectId: project.id, name: "boot"))

        #expect(process.state == .failed(-1))

        // The control for the assertion above: the same config through a launcher
        // that does hand back a handle leaves the process `.running` at exactly
        // this point, so `.failed(-1)` is reading the refusal and not something
        // every auto-started process would show.
        let permissive = ProjectStore(
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
            service: FakeTerminalService(),
            processSupervisor: ProcessSupervisor(launcher: FakeProcessLauncher())
        )
        permissive.addProject(url: workspace)
        permissive.approvePendingConfig()
        let permissiveProject = try #require(permissive.projects.first)
        let permissiveProcess = try #require(
            permissive.processes.process(projectId: permissiveProject.id, name: "boot")
        )
        #expect(permissiveProcess.state == .running)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
