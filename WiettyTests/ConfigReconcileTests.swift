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
