import Foundation

/// Why a `wietty.json` could not be read, worded for the user.
///
/// `DecodingError` on its own is unusable here: the alert shows nothing but the
/// message, and Foundation renders a missing key as "The data couldn't be read
/// because it is missing", which names neither the file nor the key. The rename
/// guarantees this is the common case rather than a rare one, since every
/// workspace file written before it lists terminals under `iterm` and so reads
/// as missing `terminals`.
enum WorkspaceConfigError: LocalizedError, Equatable {
    /// A required key is absent.
    case missingKey(String)
    /// The key is present but holds the wrong kind of value, or holds null.
    case wrongType(String)
    /// Not JSON at all, or broken somewhere no single key explains.
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let key):
            let sentence = "\(ConfigFile.fileName) is missing the required \"\(key)\" key."
            // Only `terminals` earns a hint. It is the one key the rename moved,
            // so it is the one whose absence has a known cause and a known fix.
            guard key == "terminals" else { return sentence }
            return sentence + " A workspace written before the rename lists its "
                + "terminals under \"iterm\". Rename that key to \"terminals\"."
        case .wrongType(let key):
            return "\(ConfigFile.fileName) has the wrong kind of value for \"\(key)\"."
        case .malformed(let detail):
            return "\(ConfigFile.fileName) could not be read: \(detail)"
        }
    }

    /// Maps a decoding failure onto the case that describes it. A `codingPath`
    /// is the route to the offending value, so its last element is the key worth
    /// naming; an empty path means the failure is about the document itself.
    init(_ error: DecodingError) {
        switch error {
        case .keyNotFound(let key, _):
            self = .missingKey(key.stringValue)
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            guard let key = context.codingPath.last?.stringValue else {
                self = .malformed(context.debugDescription)
                return
            }
            self = .wrongType(key)
        case .dataCorrupted(let context):
            self = .malformed(context.debugDescription)
        @unknown default:
            self = .malformed(error.localizedDescription)
        }
    }
}

/// Value model for the committed `wietty.json` file. Pure: it knows how to
/// parse and emit itself and holds no I/O or app state.
struct WorkspaceConfig: Codable, Equatable {
    struct Agent: Codable, Equatable {
        var slot: String
        var type: String
        /// When true, the row always shows `slot` and ignores the title the agent
        /// reports, rather than being relabelled by it. See issue #37.
        var fixedNaming: Bool
        /// Always prepended to the displayed name, with a single space, whatever the
        /// name is (slot, reported title, or manual rename). Empty means no prefix.
        var prefix: String

        init(slot: String, type: String, fixedNaming: Bool = false, prefix: String = "") {
            self.slot = slot
            self.type = type
            self.fixedNaming = fixedNaming
            self.prefix = prefix
        }

        /// `fixedNaming` maps to the file's `fixed_naming`; the rest keep their names.
        private enum CodingKeys: String, CodingKey {
            case slot, type, prefix
            case fixedNaming = "fixed_naming"
        }

        /// `slot` and `type` stay required: an agent entry missing either is a
        /// malformed list the loud parse failure is meant to catch. The two new
        /// fields are optional and default, so a file written before them still reads.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slot = try c.decode(String.self, forKey: .slot)
            type = try c.decode(String.self, forKey: .type)
            fixedNaming = try c.decodeIfPresent(Bool.self, forKey: .fixedNaming) ?? false
            prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        }

        /// Defaults are omitted, so a file gains `fixed_naming`/`prefix` only when set
        /// rather than every agent sprouting `"fixed_naming": false, "prefix": ""` on
        /// the next rewrite.
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(slot, forKey: .slot)
            try c.encode(type, forKey: .type)
            if fixedNaming { try c.encode(fixedNaming, forKey: .fixedNaming) }
            if !prefix.isEmpty { try c.encode(prefix, forKey: .prefix) }
        }
    }

    var name: String?
    var agents: [Agent]
    var terminals: [String]
    var processes: [String: ProcessConfig]?
    var tests: [String: TestConfig]?
    var checks: [String: CheckConfig]?
    var shellInit: [String]?

    init(name: String?, agents: [Agent], terminals: [String], processes: [String: ProcessConfig]? = nil, tests: [String: TestConfig]? = nil, checks: [String: CheckConfig]? = nil, shellInit: [String]? = nil) {
        self.name = name
        self.agents = agents
        self.terminals = terminals
        self.processes = processes
        self.tests = tests
        self.checks = checks
        self.shellInit = shellInit
    }

    /// Spelled out so `shellInit` maps to the file's `shell_init`; the rest keep
    /// the names the synthesized conformance would have used.
    private enum CodingKeys: String, CodingKey {
        case name, agents, terminals, processes, tests, checks
        case shellInit = "shell_init"
    }

    static func parse(_ data: Data) throws -> WorkspaceConfig {
        do {
            return try JSONDecoder().decode(WorkspaceConfig.self, from: data)
        } catch let error as DecodingError {
            throw WorkspaceConfigError(error)
        }
    }

    /// Pretty, key-sorted JSON with a trailing newline so the file is stable and
    /// diff friendly. Array order is preserved as written. Slashes are left
    /// unescaped so a command path reads as `/usr/local/bin/x`, the way it was
    /// written by hand, rather than Foundation's default `\/`.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
