import Foundation

/// How a process runs and is stopped. Raw values are the on-disk `kind` strings.
enum ProcessKind: String, Codable, Equatable {
    case longRunning = "long_running"
    case daemon
    case shortRunning = "short_running"
}

/// One process definition from `wietty.json`. The file is the source of truth:
/// the app never edits a definition, but it does re-encode the ones it decoded,
/// because rewriting the file (when terminal rows change) reconstructs it from
/// the definitions held on `Project`. A decoded definition must therefore keep
/// saying exactly what the file said.
struct ProcessConfig: Codable, Equatable {
    var command: String
    var kind: ProcessKind
    var stop: String?
    var status: String?
    var autoStart: Bool
    var autoRestart: Bool
    var restartWhenChanged: [String]
    var env: [String: String]
    /// When false (the default), a command that references an `WIETTY_*`
    /// variable with no value is blocked rather than run with the variable
    /// expanding to empty. Set true to opt into empty expansion.
    var allowEmptyVars: Bool
    /// This definition's own shell lines, run in the same shell as `command`,
    /// `stop`, and `status`, before each of them. Always just what the file says:
    /// the supervisor merges the workspace-wide lines ahead of these into a
    /// separate effective prelude, so this field is never the merged list.
    var shellInit: [String]

    init(
        command: String,
        kind: ProcessKind = .longRunning,
        stop: String? = nil,
        status: String? = nil,
        autoStart: Bool = false,
        autoRestart: Bool = false,
        restartWhenChanged: [String] = [],
        env: [String: String] = [:],
        allowEmptyVars: Bool = false,
        shellInit: [String] = []
    ) {
        self.command = command
        self.kind = kind
        self.stop = stop
        self.status = status
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.restartWhenChanged = restartWhenChanged
        self.env = env
        self.allowEmptyVars = allowEmptyVars
        self.shellInit = shellInit
    }

    private enum CodingKeys: String, CodingKey {
        case command, kind, stop, status
        case autoStart = "auto_start"
        case autoRestart = "auto_restart"
        case restartWhenChanged = "restart_when_changed"
        case env
        case allowEmptyVars = "allow_empty_vars"
        case shellInit = "shell_init"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        kind = try c.decodeIfPresent(ProcessKind.self, forKey: .kind) ?? .longRunning
        stop = try c.decodeIfPresent(String.self, forKey: .stop)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoRestart = try c.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        restartWhenChanged = try c.decodeIfPresent([String].self, forKey: .restartWhenChanged) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        allowEmptyVars = try c.decodeIfPresent(Bool.self, forKey: .allowEmptyVars) ?? false
        shellInit = try c.decodeIfPresent([String].self, forKey: .shellInit) ?? []
    }
}
