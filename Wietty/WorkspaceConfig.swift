import Foundation

/// Value model for the committed `wietty.json` file. Pure: it knows how to
/// parse and emit itself and holds no I/O or app state.
struct WorkspaceConfig: Codable, Equatable {
    struct Agent: Codable, Equatable {
        var slot: String
        var type: String
    }

    var name: String?
    var agents: [Agent]
    var terminals: [String]
    var processes: [String: ProcessConfig]?
    var tests: [String: TestConfig]?
    var shellInit: [String]?

    init(name: String?, agents: [Agent], terminals: [String], processes: [String: ProcessConfig]? = nil, tests: [String: TestConfig]? = nil, shellInit: [String]? = nil) {
        self.name = name
        self.agents = agents
        self.terminals = terminals
        self.processes = processes
        self.tests = tests
        self.shellInit = shellInit
    }

    /// Spelled out so `shellInit` maps to the file's `shell_init`; the rest keep
    /// the names the synthesized conformance would have used.
    private enum CodingKeys: String, CodingKey {
        case name, agents, terminals, processes, tests
        case shellInit = "shell_init"
    }

    static func parse(_ data: Data) throws -> WorkspaceConfig {
        try JSONDecoder().decode(WorkspaceConfig.self, from: data)
    }

    /// Pretty, key-sorted JSON with a trailing newline so the file is stable and
    /// diff friendly. Array order is preserved as written.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
