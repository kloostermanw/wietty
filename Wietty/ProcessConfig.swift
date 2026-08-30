import Foundation

/// How a process runs and is stopped. Raw values are the on-disk `kind` strings.
enum ProcessKind: String, Codable, Equatable {
    case longRunning = "long_running"
    case daemon
    case shortRunning = "short_running"
}

/// One process definition from `wietty.json`. The file is the source of truth, and
/// the app re-encodes the definitions it decoded whenever it rewrites the file
/// (a row change, or an edit from the Edit workspace page), reconstructing them from
/// the definitions held on `Project`. A decoded definition must therefore keep
/// saying exactly what the file said, so a rewrite that touches a neighbour does not
/// rewrite it. The Edit workspace page (`ProjectStore.updateProcess`) is the one path
/// that changes a definition on purpose.
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

    /// Defaults and empty collections are omitted, so re-encoding a decoded
    /// definition keeps saying exactly what the file said rather than adding
    /// `auto_start: false`, `env: {}` and the rest of the defaults as noise. The
    /// round trip still holds: `init(from:)` restores each omitted field to the
    /// same default it was omitted for. `command` and `kind` are always written.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(stop, forKey: .stop)
        try c.encodeIfPresent(status, forKey: .status)
        if autoStart { try c.encode(autoStart, forKey: .autoStart) }
        if autoRestart { try c.encode(autoRestart, forKey: .autoRestart) }
        if !restartWhenChanged.isEmpty { try c.encode(restartWhenChanged, forKey: .restartWhenChanged) }
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if allowEmptyVars { try c.encode(allowEmptyVars, forKey: .allowEmptyVars) }
        if !shellInit.isEmpty { try c.encode(shellInit, forKey: .shellInit) }
    }
}
