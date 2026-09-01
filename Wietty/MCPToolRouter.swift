import Foundation

/// Describes one MCP tool for `tools/list`.
struct MCPToolDescriptor: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

enum MCPToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String)
    case unknownProject(String)
    case unknownSession(String)
    case unknownManagedProcess(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name): return "Unknown tool: \(name)."
        case let .missingArgument(key): return "Missing required argument: \(key)."
        case let .invalidArgument(detail): return "Invalid argument: \(detail)."
        case let .unknownProject(id): return "No workspace with id \(id)."
        case let .unknownSession(id): return "No tracked terminal with session id \(id)."
        case let .unknownManagedProcess(id): return "No managed process or test with id \(id)."
        case let .failed(message): return message
        }
    }
}

/// Maps MCP tool calls onto the live `ProjectStore`, so every result reflects
/// exactly what the Wietty UI shows. Kept independent of the MCP SDK types
/// (`MCPServerHost` adapts between them) so it can be unit-tested directly.
@MainActor
final class MCPToolRouter {
    private let store: ProjectStore
    /// Default workspace used when a tool omits `project_id`. Set by
    /// `select_project`; persists for the server's lifetime.
    private(set) var selectedProjectId: UUID?

    private static let maxOutputLines = 200

    init(store: ProjectStore) {
        self.store = store
    }

    // MARK: - Dispatch

    func call(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "list_projects": return listProjects()
        case "get_project": return try getProject(arguments)
        case "create_project": return try createProject(arguments)
        case "delete_project": return try deleteProject(arguments)
        case "select_project": return try selectProject(arguments)
        case "list_processes": return try listProcesses(arguments)
        case "get_process_status": return try getProcessStatus(arguments)
        case "spawn_process": return try await spawnProcess(arguments, forceKind: nil)
        case "spawn_agent": return try await spawnProcess(arguments, forceKind: .claude)
        case "send_input": return try await sendInput(arguments)
        case "close_process": return try await closeProcess(arguments)
        case "select_process": return try await selectProcess(arguments)
        case "rename_process": return try renameProcess(arguments)
        case "get_process_output": return try await getProcessOutput(arguments)
        case "restart_process": return try await restartProcess(arguments)
        case "list_managed_processes": return try listManagedProcesses(arguments)
        case "get_managed_process_output": return try getManagedProcessOutput(arguments)
        case "get_managed_process_status": return try getManagedProcessStatus(arguments)
        case "list_tests": return try listTests(arguments)
        case "run_test": return try runTest(arguments)
        case "run_all_tests": return try runAllTests(arguments)
        default: throw MCPToolError.unknownTool(name)
        }
    }

    // MARK: - Tool handlers

    private func listProjects() -> JSONValue {
        .object(["projects": .array(store.projects.map(projectSummary))])
    }

    private func getProject(_ args: [String: JSONValue]) throws -> JSONValue {
        try projectDetail(resolveProject(args))
    }

    private func createProject(_ args: [String: JSONValue]) throws -> JSONValue {
        let path = try requireString(args, "path")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        store.addProject(url: url)
        guard let project = store.projects.first(where: {
            $0.url.standardizedFileURL.path == url.path
        }) else {
            throw MCPToolError.failed("Could not add a workspace at \(path). The folder must exist.")
        }
        return projectDetail(project)
    }

    private func deleteProject(_ args: [String: JSONValue]) throws -> JSONValue {
        let project = try resolveProject(args)
        store.remove(project)
        if selectedProjectId == project.id { selectedProjectId = nil }
        return .object(["deleted": .bool(true), "project_id": .string(project.id.uuidString)])
    }

    private func selectProject(_ args: [String: JSONValue]) throws -> JSONValue {
        let project = try resolveProject(args)
        selectedProjectId = project.id
        return .object(["selected_project": projectSummary(project)])
    }

    private func listProcesses(_ args: [String: JSONValue]) throws -> JSONValue {
        let projects: [Project]
        if args["project_id"] != nil { projects = [try resolveProject(args)] }
        else { projects = store.projects }
        let items = projects.flatMap { project in
            project.terminals.map { terminalJSON($0, in: project) }
        }
        return .object(["processes": .array(items)])
    }

    private func getProcessStatus(_ args: [String: JSONValue]) throws -> JSONValue {
        let (project, ref) = try resolveTerminal(args)
        return terminalJSON(ref, in: project)
    }

    private func spawnProcess(_ args: [String: JSONValue], forceKind: TerminalKind?) async throws -> JSONValue {
        let project = try resolveProject(args)
        let kind: TerminalKind
        if let forceKind { kind = forceKind }
        else {
            let raw = args["kind"]?.stringValue ?? TerminalKind.terminal.rawValue
            guard let parsed = TerminalKind(rawValue: raw) else {
                throw MCPToolError.invalidArgument("kind must be 'terminal' or 'claude'")
            }
            kind = parsed
        }
        let ref = try await store.openSessionThrowing(for: project, kind: kind)
        return terminalJSON(ref, in: currentProject(project.id) ?? project)
    }

    private func sendInput(_ args: [String: JSONValue]) async throws -> JSONValue {
        let (_, ref) = try resolveTerminal(args)
        guard let text = args["text"]?.stringValue else { throw MCPToolError.missingArgument("text") }
        try await store.sendText(Self.submitting(text), toSessionId: ref.sessionId)
        return .object(["sent": .bool(true), "session_id": .string(ref.sessionId)])
    }

    /// Rewrites newlines to carriage returns so a `\n` in `send_input` text submits
    /// the line the way pressing Return does.
    ///
    /// A terminal reports the Return key as CR (0x0D), never LF (0x0A). A cooked mode
    /// shell maps that CR to NL through its line discipline (ICRNL), and a raw mode
    /// reader such as Claude Code treats CR as submit, so CR is what works for both.
    /// A bare LF submits only under cooked mode: a raw mode reader takes it as a
    /// literal newline and inserts a blank line instead of running the input, which
    /// is why a trailing `\n` looked ignored against a running agent. The remote
    /// keystroke path already sends CR, because its clients forward real key events,
    /// so this rewrite lives here at the MCP boundary and leaves that path untouched.
    /// CRLF collapses to a single CR, so "cmd\r\n" is one Return and not two.
    static func submitting(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
    }

    private func closeProcess(_ args: [String: JSONValue]) async throws -> JSONValue {
        let (_, ref) = try resolveTerminal(args)
        try await store.closeSession(sessionId: ref.sessionId)
        return .object(["closed": .bool(true), "session_id": .string(ref.sessionId)])
    }

    private func selectProcess(_ args: [String: JSONValue]) async throws -> JSONValue {
        let (_, ref) = try resolveTerminal(args)
        let result = try await store.focus(sessionId: ref.sessionId)
        return .object([
            "found": .bool(result.found),
            "job_name": result.jobName.map(JSONValue.string) ?? .null,
        ])
    }

    private func renameProcess(_ args: [String: JSONValue]) throws -> JSONValue {
        let (project, ref) = try resolveTerminal(args)
        let name = try requireString(args, "name")
        store.rename(ref, in: project, to: name)
        let updated = currentProject(project.id)?.terminals.first { $0.id == ref.id } ?? ref
        return terminalJSON(updated, in: currentProject(project.id) ?? project)
    }

    private func getProcessOutput(_ args: [String: JSONValue]) async throws -> JSONValue {
        let (_, ref) = try resolveTerminal(args)
        let requested = args["lines"]?.intValue ?? 50
        let lines = max(1, min(requested, Self.maxOutputLines))
        let output = try await store.readOutput(sessionId: ref.sessionId, maxLines: lines)
        return .object(["session_id": .string(ref.sessionId), "output": .string(output)])
    }

    private func restartProcess(_ args: [String: JSONValue]) async throws -> JSONValue {
        let (_, ref) = try resolveTerminal(args)
        let updated = try await store.restart(sessionId: ref.sessionId)
        let project = store.projects.first { $0.terminals.contains { $0.id == updated.id } }
        return terminalJSON(updated, in: project ?? Project(url: URL(fileURLWithPath: "/")))
    }

    // MARK: - Managed processes and tests

    /// Unlike a terminal session, a managed process or test is not a PTY. It is a
    /// supervised command with a captured log, so the surface here is read only:
    /// list what a workspace runs, and read one's recent output or status by the
    /// `ManagedProcessID` handle the sidebar's "Copy ID for agent" action produces.
    private func listManagedProcesses(_ args: [String: JSONValue]) throws -> JSONValue {
        let projects: [Project]
        if args["project_id"] != nil { projects = [try resolveProject(args)] }
        else { projects = store.projects }
        let items = projects.flatMap { project -> [JSONValue] in
            let processes = store.processes.processes(for: project.id)
                .map { managedProcessJSON($0, isTest: false, in: project) }
            let tests = store.testSupervisor.tests(for: project.id)
                .map { managedProcessJSON($0, isTest: true, in: project) }
            return processes + tests
        }
        return .object(["managed_processes": .array(items)])
    }

    private func getManagedProcessOutput(_ args: [String: JSONValue]) throws -> JSONValue {
        let (id, process, _, _) = try resolveManagedProcess(args)
        let requested = args["lines"]?.intValue ?? 50
        let lines = max(1, min(requested, Self.maxOutputLines))
        let output = process.log.lines.suffix(lines).joined(separator: "\n")
        return .object(["id": .string(id), "output": .string(output)])
    }

    private func getManagedProcessStatus(_ args: [String: JSONValue]) throws -> JSONValue {
        let (_, process, parsed, project) = try resolveManagedProcess(args)
        return managedProcessJSON(process, isTest: parsed.isTest, in: project)
    }

    /// Lists only the tests a workspace declares, a narrower view than
    /// `list_managed_processes` (which also carries `processes`) for an agent that
    /// means to run the checks. Ids and shape match, so what this returns feeds
    /// straight into `run_test`.
    private func listTests(_ args: [String: JSONValue]) throws -> JSONValue {
        let projects: [Project]
        if args["project_id"] != nil { projects = [try resolveProject(args)] }
        else { projects = store.projects }
        let items = projects.flatMap { project in
            store.testSupervisor.tests(for: project.id)
                .map { managedProcessJSON($0, isTest: true, in: project) }
        }
        return .object(["tests": .array(items)])
    }

    /// Runs one test by its id and reports the status the run left it in.
    ///
    /// A well-formed id naming a process rather than a test is rejected instead of
    /// resolved by name: the supervisor looks tests up by name alone, and a process
    /// and a test may share one (see `ManagedProcessID`), so the unguarded call would
    /// start the same-named *test* and return the process row labelled as one.
    ///
    /// A test already in flight is refused rather than reported as started. The two
    /// are otherwise indistinguishable in the response, and an agent that polls
    /// afterwards would read the in-flight run's verdict as the verdict on its own
    /// change.
    private func runTest(_ args: [String: JSONValue]) throws -> JSONValue {
        let (id, process, parsed, project) = try resolveManagedProcess(args)
        guard parsed.isTest else {
            throw MCPToolError.invalidArgument("id is not a test: \(id)")
        }
        guard store.testSupervisor.run(projectId: project.id, name: parsed.name) else {
            throw MCPToolError.failed(
                "Test \(parsed.name) is already running, so this call started nothing. Its "
                + "result will not reflect changes made since it launched. Wait for it with "
                + "get_managed_process_status, then run it again."
            )
        }
        return managedProcessJSON(process, isTest: true, in: project, started: true)
    }

    /// Runs every test in a workspace and reports the status each was left in.
    /// Unlike `run_test` an overlapping run is not an error here, since a fan-out
    /// routinely meets one test already in flight, so each row carries `started` to
    /// say whether this call is what launched it.
    ///
    /// Requires `project_id` or a `select_project` default, unlike `list_tests`,
    /// which spans every workspace when scoping is omitted. Running every test in
    /// every workspace is not a reasonable reading of an omitted argument.
    private func runAllTests(_ args: [String: JSONValue]) throws -> JSONValue {
        let project = try resolveProject(args)
        let started = store.testSupervisor.runAll(projectId: project.id)
        let items = store.testSupervisor.tests(for: project.id)
            .map { managedProcessJSON($0, isTest: true, in: project, started: started.contains($0.name)) }
        return .object(["tests": .array(items)])
    }

    // MARK: - Resolution helpers

    private func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return value
    }

    private func currentProject(_ id: UUID) -> Project? {
        store.projects.first { $0.id == id }
    }

    private func resolveProject(_ args: [String: JSONValue]) throws -> Project {
        if let idString = args["project_id"]?.stringValue {
            guard let uuid = UUID(uuidString: idString),
                  let project = store.projects.first(where: { $0.id == uuid }) else {
                throw MCPToolError.unknownProject(idString)
            }
            return project
        }
        if let name = args["name"]?.stringValue,
           let project = store.projects.first(where: { $0.name == name }) {
            return project
        }
        if let selectedProjectId,
           let project = store.projects.first(where: { $0.id == selectedProjectId }) {
            return project
        }
        throw MCPToolError.missingArgument("project_id")
    }

    private func resolveTerminal(_ args: [String: JSONValue]) throws -> (Project, TerminalRef) {
        let sessionId = try requireString(args, "session_id")
        for project in store.projects {
            if let ref = project.terminals.first(where: { $0.sessionId == sessionId }) {
                return (project, ref)
            }
        }
        throw MCPToolError.unknownSession(sessionId)
    }

    /// Resolves an `id` argument (a `ManagedProcessID` string) to the live process or
    /// test it names. A malformed handle is an `invalidArgument`; a well-formed handle
    /// whose workspace or definition is gone is an `unknownManagedProcess`, the same
    /// distinction `resolveTerminal` draws for a missing session.
    private func resolveManagedProcess(
        _ args: [String: JSONValue]
    ) throws -> (id: String, process: ManagedProcess, parsed: ManagedProcessID.Parsed, project: Project) {
        let id = try requireString(args, "id")
        guard let parsed = ManagedProcessID.parse(id) else {
            throw MCPToolError.invalidArgument("id is not a managed process handle: \(id)")
        }
        guard let project = store.projects.first(where: { $0.id == parsed.projectId }) else {
            throw MCPToolError.unknownManagedProcess(id)
        }
        let process = parsed.isTest
            ? store.testSupervisor.test(projectId: parsed.projectId, name: parsed.name)
            : store.processes.process(projectId: parsed.projectId, name: parsed.name)
        guard let process else { throw MCPToolError.unknownManagedProcess(id) }
        return (id, process, parsed, project)
    }

    // MARK: - Serialization

    private var serializer: WorkspaceSerializer { WorkspaceSerializer(store: store) }

    private func projectSummary(_ project: Project) -> JSONValue {
        .object([
            "id": .string(project.id.uuidString),
            "name": .string(project.name),
            "path": .string(project.url.path),
            "is_git_repository": .bool(project.isGitRepository),
            "terminal_count": .int(project.terminals.count),
            "selected": .bool(project.id == selectedProjectId),
        ])
    }

    private func projectDetail(_ project: Project) -> JSONValue {
        // Preserve the summary fields MCP adds on top of the shared shape.
        guard case var .object(members) = serializer.workspace(project) else { return serializer.workspace(project) }
        members["path"] = .string(project.url.path)
        members["is_git_repository"] = .bool(project.isGitRepository)
        members["terminal_count"] = .int(project.terminals.count)
        members["selected"] = .bool(project.id == selectedProjectId)
        return .object(members)
    }

    private func terminalJSON(_ ref: TerminalRef, in project: Project) -> JSONValue {
        WorkspaceSerializer.terminal(ref, projectId: project.id, projectName: project.name,
                                     displayLabel: store.displayName(for: ref),
                                     runState: store.runState(for: ref),
                                     needsAttention: store.attention.contains(ref.id),
                                     jobName: store.jobNames[ref.id])
    }

    /// A managed process or test is serialized only for the MCP surface (not the shared
    /// `WorkspaceSerializer`, which is the LAN protocol's shape too), so it is defined
    /// here rather than there.
    ///
    /// `started` is carried only by the run tools, which need to say whether this
    /// call is what launched the test; the read-only tools leave it off.
    private func managedProcessJSON(
        _ process: ManagedProcess, isTest: Bool, in project: Project, started: Bool? = nil
    ) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(ManagedProcessID.string(projectId: project.id, name: process.name, isTest: isTest)),
            "name": .string(process.name),
            "type": .string(isTest ? "test" : "process"),
            "status": .string(Self.statusString(process.state)),
            "running": .bool(processIsRunning(for: process.state)),
            "project_id": .string(project.id.uuidString),
            "project_name": .string(project.name),
        ]
        if case let .failed(code) = process.state { members["exit_code"] = .int(Int(code)) }
        if let started { members["started"] = .bool(started) }
        return .object(members)
    }

    private static func statusString(_ state: ProcessState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "running"
        case .finished: return "finished"
        case .failed: return "failed"
        case .stopping: return "stopping"
        case .orphaned: return "orphaned"
        }
    }

    // MARK: - Tool catalog

    func toolDescriptors() -> [MCPToolDescriptor] {
        [
            .init(name: "list_projects",
                  description: "List all Wietty workspaces (folders) with their id, name, path, and terminal count.",
                  inputSchema: Self.schema(properties: [:], required: [])),
            .init(name: "get_project",
                  description: "Get a workspace's details including its terminals and git status. Uses the selected workspace if project_id is omitted.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Workspace id")], required: [])),
            .init(name: "create_project",
                  description: "Add an existing folder as a workspace. The folder must already exist on disk.",
                  inputSchema: Self.schema(properties: ["path": Self.stringProp("Absolute path to the folder")], required: ["path"])),
            .init(name: "delete_project",
                  description: "Remove a workspace from Wietty. Uses the selected workspace if project_id is omitted.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Workspace id")], required: [])),
            .init(name: "select_project",
                  description: "Set the default workspace used by later tool calls that omit project_id.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Workspace id")], required: ["project_id"])),
            .init(name: "list_processes",
                  description: "List terminal and claude sessions, with run state, foreground job, and attention flag. Optionally scoped to one workspace.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Optional workspace id to scope to")], required: [])),
            .init(name: "get_process_status",
                  description: "Get the status of one session by its session id.",
                  inputSchema: Self.schema(properties: ["session_id": Self.stringProp("terminal session id")], required: ["session_id"])),
            .init(name: "spawn_process",
                  description: "Open a new session in a workspace. kind is 'terminal' (default) or 'claude'.",
                  inputSchema: Self.schema(properties: [
                    "project_id": Self.stringProp("Workspace id (defaults to selected)"),
                    "kind": Self.stringProp("'terminal' or 'claude'"),
                  ], required: [])),
            .init(name: "spawn_agent",
                  description: "Open a new claude session in a workspace (shorthand for spawn_process with kind=claude).",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Workspace id (defaults to selected)")], required: [])),
            .init(name: "send_input",
                  description: "Send text to a session. Include a newline (\\n) to submit; every newline is sent as a Return.",
                  inputSchema: Self.schema(properties: [
                    "session_id": Self.stringProp("terminal session id"),
                    "text": Self.stringProp("Text to send. Each newline (\\n or \\r\\n) is rewritten to a carriage return, so it submits the line the way pressing Return does."),
                  ], required: ["session_id", "text"])),
            .init(name: "close_process",
                  description: "Close a session and drop it from the workspace.",
                  inputSchema: Self.schema(properties: ["session_id": Self.stringProp("terminal session id")], required: ["session_id"])),
            .init(name: "select_process",
                  description: "Show a session in the terminal pane and bring the app forward. Returns whether it was found and its foreground job.",
                  inputSchema: Self.schema(properties: ["session_id": Self.stringProp("terminal session id")], required: ["session_id"])),
            .init(name: "rename_process",
                  description: "Rename a session's label in Wietty.",
                  inputSchema: Self.schema(properties: [
                    "session_id": Self.stringProp("terminal session id"),
                    "name": Self.stringProp("New label"),
                  ], required: ["session_id", "name"])),
            .init(name: "get_process_output",
                  description: "Read recent rendered terminal output for a session (most recent lines last, up to 200).",
                  inputSchema: Self.schema(properties: [
                    "session_id": Self.stringProp("terminal session id"),
                    "lines": Self.intProp("Number of trailing lines (default 50, max 200)"),
                  ], required: ["session_id"])),
            .init(name: "restart_process",
                  description: "Restart a session: close it and open a fresh one in the same window, re-running its command (claude for claude sessions).",
                  inputSchema: Self.schema(properties: ["session_id": Self.stringProp("terminal session id")], required: ["session_id"])),
            .init(name: "list_managed_processes",
                  description: "List a workspace's managed processes and tests (defined in wietty.json), with their id, name, type ('process' or 'test'), status, and whether they are running. Each id is the same handle the sidebar's 'Copy ID for agent' action copies. Optionally scoped to one workspace.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Optional workspace id to scope to")], required: [])),
            .init(name: "get_managed_process_output",
                  description: "Read recent log output for a managed process or test by its id (most recent lines last, up to 200).",
                  inputSchema: Self.schema(properties: [
                    "id": Self.stringProp("managed process or test id (from list_managed_processes or 'Copy ID for agent')"),
                    "lines": Self.intProp("Number of trailing lines (default 50, max 200)"),
                  ], required: ["id"])),
            .init(name: "get_managed_process_status",
                  description: "Get the status of one managed process or test by its id.",
                  inputSchema: Self.schema(properties: [
                    "id": Self.stringProp("managed process or test id (from list_managed_processes or 'Copy ID for agent')"),
                  ], required: ["id"])),
            .init(name: "list_tests",
                  description: "List a workspace's tests (defined in wietty.json), in the same row shape list_managed_processes returns. Narrower than that tool, which also includes processes. Each id feeds run_test. Omit project_id to list every workspace's tests; this does not fall back to the selected workspace.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Optional workspace id to scope to; omitted lists every workspace")], required: [])),
            .init(name: "run_test",
                  description: "Run one test by its id (from list_tests or list_managed_processes) and return the status the run left it in: running, or failed with exit_code -1 when the launch was blocked or refused. Errors if the test is already running, since that call would start nothing. Read the result afterwards with get_managed_process_status / get_managed_process_output; it is done when the status reaches finished or failed.",
                  inputSchema: Self.schema(properties: ["id": Self.stringProp("test id")], required: ["id"])),
            .init(name: "run_all_tests",
                  description: "Run every test in a workspace and return the status each was left in. A test already running is left alone rather than restarted, so each row carries started: true/false saying whether this call launched it. Uses the selected workspace if project_id is omitted.",
                  inputSchema: Self.schema(properties: ["project_id": Self.stringProp("Workspace id (defaults to selected)")], required: [])),
        ]
    }

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
        ])
    }

    private static func stringProp(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func intProp(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
