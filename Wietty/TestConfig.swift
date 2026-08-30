import Foundation

/// One test-process definition from the `tests` section of `wietty.json`. A
/// test is a run-to-completion check: exit 0 = pass, non-zero = fail. Read-only
/// in the app (the file is the source of truth); `Codable` for symmetry/tests.
struct TestConfig: Codable, Equatable {
    var command: String
    var env: [String: String]
    /// When false (the default), a command that references an `WIETTY_*`
    /// variable with no value is blocked rather than run with the variable
    /// expanding to empty. Set true to opt into empty expansion.
    var allowEmptyVars: Bool
    /// This test's own shell lines, run in the same shell as `command`, before it.
    /// Always just what the file says: the supervisor merges the workspace-wide
    /// lines ahead of these into a separate effective prelude.
    var shellInit: [String]

    init(command: String, env: [String: String] = [:], allowEmptyVars: Bool = false, shellInit: [String] = []) {
        self.command = command
        self.env = env
        self.allowEmptyVars = allowEmptyVars
        self.shellInit = shellInit
    }

    private enum CodingKeys: String, CodingKey {
        case command, env
        case allowEmptyVars = "allow_empty_vars"
        case shellInit = "shell_init"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        allowEmptyVars = try c.decodeIfPresent(Bool.self, forKey: .allowEmptyVars) ?? false
        shellInit = try c.decodeIfPresent([String].self, forKey: .shellInit) ?? []
    }

    /// Defaults and empty collections are omitted, so re-encoding a decoded
    /// definition does not add `env: {}`, `allow_empty_vars: false` and
    /// `shell_init: []` as noise. `init(from:)` restores each omitted field to the
    /// same default it was omitted for, so the round trip holds. `command` is
    /// always written.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if allowEmptyVars { try c.encode(allowEmptyVars, forKey: .allowEmptyVars) }
        if !shellInit.isEmpty { try c.encode(shellInit, forKey: .shellInit) }
    }
}
