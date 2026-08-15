import Testing
import Foundation
@testable import Wietty

@Suite struct ConfigReconcileTests {
    @Test func buildsConfigFromRowsPreservingOrder() {
        let rows = [
            TerminalRef(label: "Claude 1", sessionId: "s1", kind: .claude, slot: "claude1"),
            TerminalRef(label: "Terminal 1", sessionId: "s2", kind: .terminal, slot: "Terminal 1"),
            TerminalRef(label: "fix bug", sessionId: "s3", kind: .claude, slot: "claude2"),
        ]
        let config = ConfigReconcile.config(from: rows, name: "acme")
        #expect(config.name == "acme")
        #expect(config.agents.map(\.slot) == ["claude1", "claude2"])
        #expect(config.terminals == ["Terminal 1"])
    }

    /// An agent row's `type` is what it runs, so a workspace that syncs its file can
    /// write a row for something other than Claude down. Emitting `claude` for every
    /// agent row rewrote a Codex row as a Claude row on the next apply.
    @Test func anAgentRowsTypeIsTheLineItRuns() {
        let rows = [
            TerminalRef(label: "Codex 1", sessionId: "s1", kind: .claude, slot: "codex1",
                        command: "codex --model o3"),
            TerminalRef(label: "Claude 1", sessionId: "s2", kind: .claude, slot: "claude1"),
        ]
        let config = ConfigReconcile.config(from: rows, name: nil)
        #expect(config.agents.map(\.type) == ["codex --model o3", "claude"])
    }

    /// And back: a row built from the file runs the `type` it was written with. A
    /// plain `claude` stays a row with no line of its own, which is what every file
    /// written before this said and what a hand written file says.
    @Test func aRowFromTheFileRunsTheTypeItWasWrittenWith() {
        let config = WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "codex1", type: "codex --model o3"),
                     .init(slot: "claude1", type: "claude")],
            terminals: [])
        let result = ConfigReconcile.apply(config, to: [])
        #expect(result.terminals.map(\.command) == ["codex --model o3", nil])
    }

    /// A row that is not running takes its line from the file, so a `type` edited on
    /// disk reaches the row it names rather than being kept out by what it ran before.
    @Test func anIdleRowTakesTheLineTheFileGivesIt() {
        let idle = TerminalRef(label: "codex1", sessionId: "", kind: .claude, slot: "codex1",
                               command: "codex")
        let config = WorkspaceConfig(
            name: nil, agents: [.init(slot: "codex1", type: "codex --model o3")], terminals: [])
        let result = ConfigReconcile.apply(config, to: [idle])
        #expect(result.terminals.map(\.command) == ["codex --model o3"])
    }

    /// But a running row keeps what it was started with. A file older than
    /// configurable agents says `claude` for every agent row, and applying that to a
    /// live Codex row wiped its line, leaving a row still labelled "Codex 1" that
    /// typed `claude` into Codex on the next restart.
    @Test func aRunningRowKeepsItsLineWhenTheFileDisagrees() {
        let running = TerminalRef(label: "Codex 1", sessionId: "live-1", kind: .claude,
                                  slot: "codex1", command: "codex --model o3")
        let config = WorkspaceConfig(
            name: nil, agents: [.init(slot: "codex1", type: "claude")], terminals: [])
        let result = ConfigReconcile.apply(config, to: [running])
        #expect(result.terminals.map(\.command) == ["codex --model o3"])
    }

    @Test func buildsConfigWithTests() {
        let rows = [TerminalRef(label: "Terminal 1", sessionId: "s1", kind: .terminal, slot: "Terminal 1")]
        let tests = ["phpstan": TestConfig(command: "phpstan analyse")]
        let config = ConfigReconcile.config(from: rows, name: nil, tests: tests)
        #expect(config.tests == tests)
    }

    @Test func buildsConfigCarryingShellInit() {
        let config = ConfigReconcile.config(
            from: [], name: nil, shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        #expect(config.shellInit == ["export PATH=$HOME/bin:$PATH"])
    }

    @Test func importCreatesEmptyRowsInFileOrder() {
        let config = WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "claude1", type: "claude")],
            terminals: ["Terminal 1"]
        )
        let result = ConfigReconcile.apply(config, to: [])
        #expect(result.terminals.map(\.slot) == ["claude1", "Terminal 1"])
        #expect(result.terminals[0].kind == .claude)
        #expect(result.terminals[0].label == "claude1")
        #expect(result.terminals[0].sessionId == "")
        #expect(result.terminals[1].kind == .terminal)
        #expect(result.localOnly.isEmpty)
    }

    @Test func matchPreservesExistingRefIdSessionAndLabel() {
        let existing = TerminalRef(label: "fix auth", sessionId: "live-1", kind: .claude, slot: "claude1")
        let config = WorkspaceConfig(name: nil, agents: [.init(slot: "claude1", type: "claude")], terminals: [])
        let result = ConfigReconcile.apply(config, to: [existing])
        #expect(result.terminals.count == 1)
        #expect(result.terminals[0].id == existing.id)
        #expect(result.terminals[0].sessionId == "live-1")
        #expect(result.terminals[0].label == "fix auth")
    }

    @Test func removedRunningRowKeptAsLocalOnly() {
        let running = TerminalRef(label: "Claude 2", sessionId: "live-2", kind: .claude, slot: "claude2")
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [])
        let result = ConfigReconcile.apply(config, to: [running])
        #expect(result.terminals.map(\.slot) == ["claude2"])
        #expect(result.localOnly == [running.id])
    }

    @Test func removedEmptyRowDropped() {
        let empty = TerminalRef(label: "claude2", sessionId: "", kind: .claude, slot: "claude2")
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [])
        let result = ConfigReconcile.apply(config, to: [empty])
        #expect(result.terminals.isEmpty)
        #expect(result.localOnly.isEmpty)
    }

    @Test func localOnlyRowsAppendedAfterFileRows() {
        let running = TerminalRef(label: "Claude 9", sessionId: "live", kind: .claude, slot: "claude9")
        let config = WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "claude1", type: "claude")],
            terminals: ["Terminal 1"]
        )
        let result = ConfigReconcile.apply(config, to: [running])
        #expect(result.terminals.map(\.slot) == ["claude1", "Terminal 1", "claude9"])
    }
}
