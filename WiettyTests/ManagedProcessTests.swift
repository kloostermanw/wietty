import Testing
import Foundation
@testable import Wietty

@MainActor
final class FakeHandle: @preconcurrency ProcessHandle, @unchecked Sendable {
    private(set) var signals: [Int32] = []
    func send(signal: Int32) { signals.append(signal) }
}

@MainActor
final class FakeLaunch: @unchecked Sendable {
    let command: String
    let environment: [String: String]
    let onOutput: @MainActor (String) -> Void
    let onExit: @MainActor (Int32) -> Void
    let handle = FakeHandle()
    init(command: String, environment: [String: String], onOutput: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) {
        self.command = command
        self.environment = environment
        self.onOutput = onOutput
        self.onExit = onExit
    }
}

@MainActor
final class FakeProcessLauncher: @preconcurrency ProcessLaunching, @unchecked Sendable {
    private(set) var launches: [FakeLaunch] = []
    /// Exit code delivered synchronously at launch for one-shot commands
    /// (status probes, stop commands). When nil, the launch stays "running".
    var immediateExit: [String: Int32] = [:]
    /// Commands whose launch throws, simulating a spawn/PTY failure.
    var failingCommands: Set<String> = []

    func launch(
        command: String,
        directory: URL,
        environment: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> ProcessHandle {
        if failingCommands.contains(command) { throw ProcessLaunchError.spawnFailed(1) }
        let launch = FakeLaunch(command: command, environment: environment, onOutput: onOutput, onExit: onExit)
        launches.append(launch)
        if let code = immediateExit[command] {
            onExit(code)
        }
        return launch.handle
    }

    var last: FakeLaunch { launches.last! }
}

@MainActor
@Suite struct ManagedProcessTests {
    let dir = URL(fileURLWithPath: "/tmp")

    @Test func shortRunningSuccessBecomesFinished() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "t", config: ProcessConfig(command: "phpunit", kind: .shortRunning), directory: dir, launcher: launcher)
        p.start()
        #expect(p.state == .running)
        launcher.last.onOutput("OK\n")
        launcher.last.onExit(0)
        #expect(p.state == .finished)
        #expect(p.log.lines == ["OK"])
    }

    @Test func shortRunningFailureCarriesExitCode() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "t", config: ProcessConfig(command: "phpunit", kind: .shortRunning), directory: dir, launcher: launcher)
        p.start()
        launcher.last.onExit(3)
        #expect(p.state == .failed(3))
    }

    @Test func resetToIdleIfFinishedClearsPassedRun() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "t", config: ProcessConfig(command: "phpunit", kind: .shortRunning), directory: dir, launcher: launcher)
        p.start()
        launcher.last.onExit(0)
        #expect(p.state == .finished)
        p.resetToIdleIfFinished()
        #expect(p.state == .idle)
    }

    @Test func resetToIdleIfFinishedLeavesFailedRun() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "t", config: ProcessConfig(command: "phpunit", kind: .shortRunning), directory: dir, launcher: launcher)
        p.start()
        launcher.last.onExit(2)
        #expect(p.state == .failed(2))
        p.resetToIdleIfFinished()
        #expect(p.state == .failed(2))
    }

    @Test func longRunningStopWithoutStopCommandSendsSIGINT() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning), directory: dir, launcher: launcher, graceInterval: .zero)
        p.start()
        p.stop()
        #expect(p.state == .stopping)
        #expect(launcher.last.handle.signals.first == SIGINT)
    }

    @Test func longRunningStopWithStopCommandRunsIt() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["sail stop"] = 0
        let p = ManagedProcess(name: "queue", config: ProcessConfig(command: "sail queue", kind: .longRunning, stop: "sail stop"), directory: dir, launcher: launcher, graceInterval: .zero)
        p.start()
        p.stop()
        #expect(launcher.launches.map(\.command).contains("sail stop"))
    }

    @Test func daemonStartBecomesRunningWhenStartExitsZero() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["sail up -d"] = 0
        let p = ManagedProcess(name: "sail", config: ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down"), directory: dir, launcher: launcher)
        p.start()
        #expect(p.state == .running)
    }

    @Test func daemonStartFailureBecomesFailed() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["sail up -d"] = 2
        let p = ManagedProcess(name: "sail", config: ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down"), directory: dir, launcher: launcher)
        p.start()
        #expect(p.state == .failed(2))
    }

    @Test func orphanedDaemonUnaffectedByStatusProbe() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["sail up -d"] = 0
        let up = ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down", status: "sail ps")
        let p = ManagedProcess(name: "sail", config: up, directory: dir, launcher: launcher)
        p.start()
        #expect(p.state == .running)
        p.markOrphaned()
        #expect(p.state == .orphaned)
        launcher.immediateExit["sail ps"] = 1
        p.probeStatus()
        #expect(p.state == .orphaned)
    }

    @Test func daemonStatusProbeSetsRunningOrIdle() {
        let launcher = FakeProcessLauncher()
        let up = ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down", status: "sail ps")
        let p = ManagedProcess(name: "sail", config: up, directory: dir, launcher: launcher)
        launcher.immediateExit["sail ps"] = 0
        p.probeStatus()
        #expect(p.state == .running)
        launcher.immediateExit["sail ps"] = 1
        p.probeStatus()
        #expect(p.state == .idle)
    }

    @Test func killSendsSIGKILL() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning), directory: dir, launcher: launcher)
        p.start()
        p.kill()
        #expect(launcher.last.handle.signals.contains(SIGKILL))
    }

    @Test func autoRestartRestartsOnUnexpectedExit() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning, autoRestart: true), directory: dir, launcher: launcher)
        p.start()
        #expect(launcher.launches.count == 1)
        launcher.last.onExit(1) // crash
        #expect(launcher.launches.count == 2) // relaunched
        #expect(p.state == .running)
    }

    @Test func daemonRestartBringsDownThenRelaunches() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["sail up -d"] = 0
        launcher.immediateExit["sail down"] = 0
        let p = ManagedProcess(name: "sail", config: ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down"), directory: dir, launcher: launcher)
        p.start()
        #expect(p.state == .running)
        p.restart()
        #expect(launcher.launches.map(\.command).contains("sail down"))
        #expect(launcher.launches.filter { $0.command == "sail up -d" }.count == 2)
        #expect(p.state == .running)
    }

    @Test func daemonRestartWithoutStopCommandJustRelaunches() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["sail up -d"] = 0
        let p = ManagedProcess(name: "sail", config: ProcessConfig(command: "sail up -d", kind: .daemon), directory: dir, launcher: launcher)
        p.start()
        #expect(p.state == .running)
        p.restart()
        #expect(launcher.launches.filter { $0.command == "sail up -d" }.count == 2)
        #expect(p.state == .running)
    }

    @Test func userStopSuppressesAutoRestart() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning, autoRestart: true), directory: dir, launcher: launcher, graceInterval: .zero)
        p.start()
        p.stop()
        launcher.last.onExit(0) // exits due to the stop
        #expect(launcher.launches.count == 1) // not relaunched
        #expect(p.state == .idle)
    }

    @Test func longRunningRestartEscalatesThenRelaunches() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning), directory: dir, launcher: launcher, graceInterval: .zero)
        p.start()
        #expect(launcher.launches.count == 1)
        p.restart()
        // Escalates (SIGINT first) rather than a lone SIGTERM, so a process that
        // ignores SIGTERM still exits.
        #expect(launcher.last.handle.signals.first == SIGINT)
        launcher.last.onExit(0) // process exits from the signal
        #expect(launcher.launches.count == 2) // relaunched once the exit lands
        #expect(p.state == .running)
    }

    @Test func longRunningStopCommandLaunchFailureEscalatesSignals() {
        let launcher = FakeProcessLauncher()
        launcher.failingCommands = ["stop.sh"]
        let p = ManagedProcess(name: "srv", config: ProcessConfig(command: "server", kind: .longRunning, stop: "stop.sh"), directory: dir, launcher: launcher, graceInterval: .zero)
        p.start()
        p.stop()
        // With a live handle, a failed stop command falls back to signalling it.
        #expect(launcher.last.handle.signals.first == SIGINT)
        #expect(p.state == .stopping)
    }

    @Test func crashLoopCapStopsRapidRestarts() {
        let launcher = FakeProcessLauncher()
        let clock = ContinuousClock.now
        let p = ManagedProcess(
            name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning, autoRestart: true),
            directory: dir, launcher: launcher, restartWindow: .seconds(60), now: { clock }
        )
        p.start()
        #expect(launcher.launches.count == 1)
        // Three rapid crashes within the window each relaunch; the fourth is capped.
        launcher.last.onExit(1); #expect(launcher.launches.count == 2)
        launcher.last.onExit(1); #expect(launcher.launches.count == 3)
        launcher.last.onExit(1); #expect(launcher.launches.count == 4)
        launcher.last.onExit(1)
        #expect(launcher.launches.count == 4) // capped, not relaunched
        #expect(p.state == .failed(1))
        // A manual start re-enables it.
        p.start()
        #expect(launcher.launches.count == 5)
    }

    @Test func crashesOutsideWindowDoNotHitCap() {
        let launcher = FakeProcessLauncher()
        var clock = ContinuousClock.now
        let p = ManagedProcess(
            name: "npm", config: ProcessConfig(command: "npm run dev", kind: .longRunning, autoRestart: true),
            directory: dir, launcher: launcher, restartWindow: .seconds(60), now: { clock }
        )
        p.start()
        // Four crashes spread far apart (window elapses between each) never cap.
        for expected in 2...5 {
            launcher.last.onExit(1)
            #expect(launcher.launches.count == expected)
            clock = clock.advanced(by: .seconds(120))
        }
    }

    // MARK: Variable injection

    @Test func injectsVariablesIntoLaunchEnvironment() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(
            name: "tower", config: ProcessConfig(command: "gittower $WIETTY_WORKSPACE_PATH", kind: .shortRunning),
            directory: dir, launcher: launcher,
            variables: { ["WIETTY_WORKSPACE_PATH": "/repos/app"] }
        )
        p.start()
        #expect(p.state == .running)
        #expect(launcher.last.environment["WIETTY_WORKSPACE_PATH"] == "/repos/app")
    }

    @Test func injectedVariablesOverrideEnvOfSameName() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "run", kind: .shortRunning, env: ["WIETTY_BRANCH": "stale"])
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher,
            variables: { ["WIETTY_BRANCH": "feature/x"] }
        )
        p.start()
        #expect(launcher.last.environment["WIETTY_BRANCH"] == "feature/x")
    }

    @Test func blocksLaunchWhenVariableUnresolved() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(
            name: "p", config: ProcessConfig(command: "gh pr view $WIETTY_PR_NUMBER", kind: .shortRunning),
            directory: dir, launcher: launcher,
            variables: { ["WIETTY_WORKSPACE_PATH": "/repos/app"] }
        )
        p.start()
        #expect(p.state == .failed(-1))
        #expect(launcher.launches.isEmpty)
        #expect(p.log.lines.contains { $0.contains("WIETTY_PR_NUMBER") })
    }

    @Test func allowEmptyVarsPermitsUnresolvedLaunch() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "gh pr view $WIETTY_PR_NUMBER", kind: .shortRunning, allowEmptyVars: true)
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher,
            variables: { [:] }
        )
        p.start()
        #expect(p.state == .running)
        #expect(launcher.launches.count == 1)
    }

    @Test func launchesWhenAllReferencedVariablesResolve() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(
            name: "p", config: ProcessConfig(command: "echo ${WIETTY_BRANCH}", kind: .shortRunning),
            directory: dir, launcher: launcher,
            variables: { ["WIETTY_BRANCH": "main"] }
        )
        p.start()
        #expect(p.state == .running)
        #expect(launcher.last.environment["WIETTY_BRANCH"] == "main")
    }

    @Test func injectsVariablesIntoStopEnvironment() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "npm run dev", kind: .longRunning, stop: "teardown $WIETTY_WORKSPACE_PATH")
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher, graceInterval: .zero,
            variables: { ["WIETTY_WORKSPACE_PATH": "/repos/app"] }
        )
        p.start()
        p.stop()
        #expect(launcher.last.command == "teardown $WIETTY_WORKSPACE_PATH")
        #expect(launcher.last.environment["WIETTY_WORKSPACE_PATH"] == "/repos/app")
    }

    @Test func blockedStopCommandSignalsInsteadOfRunning() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "npm run dev", kind: .longRunning, stop: "kill-branch $WIETTY_BRANCH")
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher, graceInterval: .zero,
            variables: { [:] }
        )
        p.start()
        #expect(p.state == .running)
        p.stop()
        // The stop command never ran; only the main command was launched.
        #expect(launcher.launches.count == 1)
        // The live process was signaled down instead.
        #expect(launcher.last.handle.signals.first == SIGINT)
        #expect(p.log.lines.contains { $0.contains("WIETTY_BRANCH") })
    }

    @Test func blockedDaemonStopWithNoHandleSettlesIdle() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "sail up -d", kind: .daemon, stop: "teardown $WIETTY_BRANCH")
        let p = ManagedProcess(
            name: "sail", config: config, directory: dir, launcher: launcher, graceInterval: .zero,
            variables: { [:] }
        )
        p.start()
        // The start command exits after launch returns, clearing the handle, so
        // the daemon is up with no live process to signal (the real steady state).
        launcher.last.onExit(0)
        #expect(p.state == .running)
        p.stop()
        // No handle to signal and the stop command is blocked, so it settles
        // idle without running teardown; only the start command ever launched.
        #expect(p.state == .idle)
        #expect(launcher.launches.count == 1)
        #expect(p.log.lines.contains { $0.contains("WIETTY_BRANCH") })
    }

    @Test func allowEmptyVarsRunsUnresolvedStopCommand() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "npm run dev", kind: .longRunning, stop: "kill-branch $WIETTY_BRANCH", allowEmptyVars: true
        )
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher, graceInterval: .zero,
            variables: { [:] }
        )
        p.start()
        p.stop()
        #expect(launcher.launches.map(\.command).contains("kill-branch $WIETTY_BRANCH"))
    }

    @Test func injectsVariablesIntoStatusEnvironment() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down", status: "check $WIETTY_BRANCH")
        let p = ManagedProcess(
            name: "sail", config: config, directory: dir, launcher: launcher,
            variables: { ["WIETTY_BRANCH": "main"] }
        )
        launcher.immediateExit["sail up -d"] = 0
        p.start()
        p.probeStatus()
        #expect(launcher.last.command == "check $WIETTY_BRANCH")
        #expect(launcher.last.environment["WIETTY_BRANCH"] == "main")
    }

    @Test func runsTheCommandUnderTheShellInitPrelude() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "fork", kind: .shortRunning,
            shellInit: ["export PATH=$HOME/bin:$PATH", "source ~/bin/env.sh"]
        )
        let p = ManagedProcess(name: "p", config: config, directory: dir, launcher: launcher)
        p.start()
        #expect(launcher.last.command == "export PATH=$HOME/bin:$PATH\nsource ~/bin/env.sh\nfork")
    }

    @Test func emptyShellInitLeavesTheCommandUnchanged() {
        let launcher = FakeProcessLauncher()
        let p = ManagedProcess(
            name: "p", config: ProcessConfig(command: "npm run dev", kind: .shortRunning),
            directory: dir, launcher: launcher
        )
        p.start()
        #expect(launcher.last.command == "npm run dev")
    }

    @Test func runsTheStopCommandUnderTheShellInitPrelude() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "npm run dev", kind: .longRunning, stop: "teardown",
            shellInit: ["export A=1"]
        )
        let p = ManagedProcess(name: "p", config: config, directory: dir, launcher: launcher, graceInterval: .zero)
        p.start()
        p.stop()
        #expect(launcher.last.command == "export A=1\nteardown")
    }

    @Test func runsTheStatusProbeUnderTheShellInitPrelude() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "sail up -d", kind: .daemon, status: "sail ps",
            shellInit: ["export A=1"]
        )
        let p = ManagedProcess(name: "sail", config: config, directory: dir, launcher: launcher)
        launcher.immediateExit["export A=1\nsail up -d"] = 0
        p.start()
        p.probeStatus()
        #expect(launcher.last.command == "export A=1\nsail ps")
    }

    @Test func blocksLaunchWhenShellInitReferencesUnresolvedVariable() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "fork", kind: .shortRunning,
            shellInit: ["source $WIETTY_WORKSPACE_PATH/.env"]
        )
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher,
            variables: { [:] }
        )
        p.start()
        #expect(p.state == .failed(-1))
        #expect(launcher.launches.isEmpty)
        #expect(p.log.lines.contains { $0.contains("WIETTY_WORKSPACE_PATH") })
    }

    @Test func allowEmptyVarsPermitsAnUnresolvedShellInitVariable() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "fork", kind: .shortRunning, allowEmptyVars: true,
            shellInit: ["source $WIETTY_WORKSPACE_PATH/.env"]
        )
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher,
            variables: { [:] }
        )
        p.start()
        #expect(p.state == .running)
        #expect(launcher.launches.count == 1)
    }

    @Test func skipsStatusProbeWhenVariableUnresolved() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "sail up -d", kind: .daemon, stop: "sail down", status: "check $WIETTY_BRANCH")
        let p = ManagedProcess(
            name: "sail", config: config, directory: dir, launcher: launcher,
            variables: { [:] }
        )
        launcher.immediateExit["sail up -d"] = 0
        p.start()
        #expect(p.state == .running)
        let launchesBefore = launcher.launches.count
        p.probeStatus()
        // The probe was skipped, so no new launch and the last state stands.
        #expect(launcher.launches.count == launchesBefore)
        #expect(p.state == .running)
    }

    /// The skip can be caused by a `shell_init` line rather than the status
    /// string, so the message must not pin the blame on the status command alone.
    @Test func skippedStatusProbeMessageNamesShellInit() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "sail up -d", kind: .daemon, status: "sail ps",
            shellInit: ["source $WIETTY_WORKSPACE_PATH/.env"]
        )
        let p = ManagedProcess(
            name: "sail", config: config, directory: dir, launcher: launcher,
            variables: { [:] }
        )
        launcher.immediateExit["source $WIETTY_WORKSPACE_PATH/.env\nsail up -d"] = 0
        p.start()
        p.probeStatus()
        #expect(p.log.lines.contains { $0.contains("shell_init") })
        #expect(p.log.lines.contains { $0.contains("WIETTY_WORKSPACE_PATH") })
    }

    @Test func blockedLaunchMessageNamesShellInit() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(
            command: "fork", kind: .shortRunning,
            shellInit: ["source $WIETTY_WORKSPACE_PATH/.env"]
        )
        let p = ManagedProcess(
            name: "p", config: config, directory: dir, launcher: launcher,
            variables: { [:] }
        )
        p.start()
        #expect(p.log.lines.contains { $0.contains("shell_init") })
    }

    /// A failed probe leaves the daemon `.idle`, indistinguishable from a service
    /// that is simply down. Surfacing the probe's own output is the only thing
    /// that explains the difference, which is why the prelude reaching `status`
    /// had to come with it: a complaining prelude line is reported as "down".
    @Test func failedStatusProbeOutputIsLogged() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        p.probeStatus()
        launcher.last.onOutput("zsh: source: no such file or directory: /nope/env.sh\n")
        launcher.last.onExit(1)
        #expect(p.state == .idle)
        // Flushed on the following poll, once the output stream has drained.
        p.probeStatus()
        #expect(p.log.lines.contains { $0.contains("no such file or directory: /nope/env.sh") })
        #expect(p.log.lines.contains { $0.contains("exited 1") })
    }

    @Test func repeatedIdenticalProbeFailureIsLoggedOnce() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        for _ in 0..<3 {
            p.probeStatus()
            launcher.last.onOutput("boom\n")
            launcher.last.onExit(1)
        }
        p.probeStatus()
        #expect(p.log.lines.filter { $0.contains("boom") }.count == 1)
    }

    /// A fault that returns after the daemon recovered is a new event, so the
    /// dedupe must not silence it forever.
    @Test func probeFailureAfterRecoveryIsLoggedAgain() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        p.probeStatus()
        launcher.last.onOutput("boom\n")
        launcher.last.onExit(1)
        p.probeStatus() // flushes the first failure
        launcher.last.onExit(0) // recovered
        #expect(p.state == .running)
        p.probeStatus()
        launcher.last.onOutput("boom\n")
        launcher.last.onExit(1)
        p.probeStatus()
        #expect(p.log.lines.filter { $0.contains("boom") }.count == 2)
    }

    @Test func successfulProbeLogsNothing() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        p.probeStatus()
        launcher.last.onOutput("sail is up\n")
        launcher.last.onExit(0)
        p.probeStatus()
        #expect(p.state == .running)
        #expect(!p.log.lines.contains { $0.contains("sail is up") })
    }

    /// A probe the next poll superseded must not report anything. Its output
    /// would otherwise be captured as the newer probe's diagnostic, and its exit
    /// code would decide health after a fresher answer already arrived.
    @Test func aSupersededProbeNeitherDecidesHealthNorContaminatesTheDiagnostic() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        p.probeStatus()
        let stale = launcher.last
        p.probeStatus() // the first probe is still in flight
        let current = launcher.last
        stale.onOutput("stale complaint\n")
        stale.onExit(1)
        #expect(p.state == .running)
        current.onOutput("real complaint\n")
        current.onExit(1)
        p.probeStatus()
        #expect(p.log.lines.contains { $0.contains("real complaint") })
        #expect(!p.log.lines.contains { $0.contains("stale complaint") })
    }

    /// A definition that drops `status` is never probed again, so a diagnostic
    /// still waiting to be flushed would be lost. It also belongs to the old
    /// definition, so it must be written before the new one takes over.
    @Test func pendingProbeFailureIsFlushedWhenTheDefinitionChanges() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        p.probeStatus()
        launcher.last.onOutput("boom\n")
        launcher.last.onExit(1)
        p.updateDefinition(ProcessConfig(command: "sail up -d", kind: .daemon))
        #expect(p.log.lines.contains { $0.contains("boom") })
    }

    /// A poll skipped because the daemon is mid-launch must still flush. The log
    /// carries no timestamps, so a diagnostic held back until the daemon settles
    /// would land after the relaunch's own output and read as if it caused it.
    @Test func pendingProbeFailureIsFlushedWhenTheNextPollIsSkipped() {
        let launcher = FakeProcessLauncher()
        let p = daemonWithProbe(launcher)
        p.probeStatus()
        launcher.last.onOutput("boom\n")
        launcher.last.onExit(1)
        launcher.immediateExit.removeValue(forKey: "sail up -d") // keep the relaunch in flight
        p.start()
        #expect(p.state == .starting)
        p.probeStatus()
        #expect(p.log.lines.contains { $0.contains("boom") })
    }

    /// The workspace-wide lines are merged for the shell but never written into
    /// the definition, so the field keeps meaning what the file said and cannot
    /// accumulate the global lines across re-applies.
    @Test func globalShellInitDoesNotLeakIntoTheDefinition() {
        let launcher = FakeProcessLauncher()
        let config = ProcessConfig(command: "fork", kind: .shortRunning, shellInit: ["export B=2"])
        let p = ManagedProcess(
            name: "p", config: config, globalShellInit: ["export A=1"],
            directory: dir, launcher: launcher
        )
        p.start()
        #expect(launcher.last.command == "export A=1\nexport B=2\nfork")
        #expect(p.config.shellInit == ["export B=2"])
    }

    /// A daemon that is up, with a status probe whose exit is driven by the test
    /// rather than delivered synchronously at launch.
    private func daemonWithProbe(_ launcher: FakeProcessLauncher) -> ManagedProcess {
        let config = ProcessConfig(command: "sail up -d", kind: .daemon, status: "sail ps")
        let p = ManagedProcess(name: "sail", config: config, directory: dir, launcher: launcher)
        launcher.immediateExit["sail up -d"] = 0
        p.start()
        return p
    }
}
