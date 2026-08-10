import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct ProcessSupervisorTests {
    let dir = URL(fileURLWithPath: "/tmp")
    let pid = UUID()

    private func config(_ procs: [String: ProcessConfig]) -> WorkspaceConfig {
        WorkspaceConfig(name: nil, agents: [], terminals: [], processes: procs)
    }

    @Test func foldsWorkspaceShellInitInAheadOfTheProcessOwnLines() {
        let launcher = FakeProcessLauncher()
        let sup = ProcessSupervisor(launcher: launcher)
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            processes: ["fork": ProcessConfig(command: "fork", autoStart: true, shellInit: ["source ~/bin/env.sh"])],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        sup.apply(config, projectId: pid, directory: dir)
        #expect(launcher.last.command == "export PATH=$HOME/bin:$PATH\nsource ~/bin/env.sh\nfork")
    }

    @Test func aChangedWorkspaceShellInitReachesAnAlreadyKnownProcess() {
        let launcher = FakeProcessLauncher()
        let sup = ProcessSupervisor(launcher: launcher)
        func config(_ lines: [String]) -> WorkspaceConfig {
            WorkspaceConfig(
                name: nil, agents: [], terminals: [],
                processes: ["fork": ProcessConfig(command: "fork")],
                shellInit: lines
            )
        }
        sup.apply(config(["export A=1"]), projectId: pid, directory: dir)
        sup.apply(config(["export A=2"]), projectId: pid, directory: dir)
        sup.process(projectId: pid, name: "fork")?.start()
        #expect(launcher.last.command == "export A=2\nfork")
    }

    @Test func applyAddsProcessesSortedByName() {
        let sup = ProcessSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["zeta": ProcessConfig(command: "z"), "alpha": ProcessConfig(command: "a")]), projectId: pid, directory: dir)
        #expect(sup.processes(for: pid).map(\.name) == ["alpha", "zeta"])
    }

    @Test func autoStartLaunchesOnApply() {
        let launcher = FakeProcessLauncher()
        let sup = ProcessSupervisor(launcher: launcher)
        sup.apply(config(["npm": ProcessConfig(command: "npm run dev", autoStart: true)]), projectId: pid, directory: dir)
        #expect(launcher.launches.map(\.command).contains("npm run dev"))
        #expect(sup.process(projectId: pid, name: "npm")?.state == .running)
    }

    @Test func removingDefinitionDropsIdleProcess() {
        let sup = ProcessSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["a": ProcessConfig(command: "a")]), projectId: pid, directory: dir)
        sup.apply(config([:]), projectId: pid, directory: dir)
        #expect(sup.processes(for: pid).isEmpty)
    }

    @Test func removingDefinitionOrphansRunningProcess() {
        let sup = ProcessSupervisor(launcher: FakeProcessLauncher())
        sup.apply(config(["a": ProcessConfig(command: "a", autoStart: true)]), projectId: pid, directory: dir)
        sup.apply(config([:]), projectId: pid, directory: dir)
        #expect(sup.process(projectId: pid, name: "a")?.state == .orphaned)
    }

    @Test func daemonAlreadyUpSkipsAutoStart() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["probe"] = 0 // status says up
        let sup = ProcessSupervisor(launcher: launcher)
        let daemon = ProcessConfig(command: "start", kind: .daemon, stop: "stop", status: "probe", autoStart: true)
        sup.apply(config(["d": daemon]), projectId: pid, directory: dir)
        #expect(!launcher.launches.map(\.command).contains("start"))
        #expect(sup.process(projectId: pid, name: "d")?.state == .running)
    }

    @Test func applyThreadsVariablesIntoLaunchEnvironment() {
        let launcher = FakeProcessLauncher()
        let sup = ProcessSupervisor(launcher: launcher)
        sup.apply(
            config(["npm": ProcessConfig(command: "npm run dev", autoStart: true)]),
            projectId: pid, directory: dir,
            variables: { ["WIETTY_WORKSPACE_PATH": "/repos/app"] }
        )
        #expect(launcher.last.environment["WIETTY_WORKSPACE_PATH"] == "/repos/app")
    }

    @Test func removeWorkspaceRunsDaemonStopCommand() {
        let launcher = FakeProcessLauncher()
        launcher.immediateExit["up"] = 0
        let sup = ProcessSupervisor(launcher: launcher)
        let daemon = ProcessConfig(command: "up", kind: .daemon, stop: "down", autoStart: true)
        sup.apply(config(["d": daemon]), projectId: pid, directory: dir)
        #expect(sup.process(projectId: pid, name: "d")?.state == .running)
        sup.removeWorkspace(pid)
        #expect(launcher.launches.map(\.command).contains("down"))
        #expect(sup.processes(for: pid).isEmpty)
    }
}
