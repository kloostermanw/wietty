import Foundation

/// Single source of truth for the workspace/git/terminal JSON shape shared by
/// the MCP surface and the LAN control API.
@MainActor
struct WorkspaceSerializer {
    let store: ProjectStore

    func workspaces() -> JSONValue {
        .object(["workspaces": .array(store.projects.map(workspace))])
    }

    func workspace(_ project: Project) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(project.id.uuidString),
            "name": .string(project.name),
        ]
        members["terminals"] = .array(project.terminals.map { ref in
            Self.terminal(ref, projectId: project.id, projectName: project.name,
                          runState: store.runState(for: ref),
                          needsAttention: store.attention.contains(ref.id),
                          jobName: store.jobNames[ref.id])
        })
        if let info = store.gitInfo[project.id] { members["git"] = Self.git(info) }
        return .object(members)
    }

    static func terminal(_ ref: TerminalRef, projectId: UUID, projectName: String,
                         runState: ClaudeRunState, needsAttention: Bool, jobName: String?) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(ref.id.uuidString),
            "session_id": .string(ref.sessionId),
            "label": .string(ref.label),
            "kind": .string(ref.kind.rawValue),
            "run_state": .string(runState == .running ? "running" : "exited"),
            "needs_attention": .bool(needsAttention),
            "project_id": .string(projectId.uuidString),
            "project_name": .string(projectName),
        ]
        if let jobName { members["job_name"] = .string(jobName) }
        return .object(members)
    }

    static func git(_ info: GitInfo) -> JSONValue {
        var members: [String: JSONValue] = [
            "branch": .string(info.branch),
            "ahead": .int(info.ahead),
            "behind": .int(info.behind),
            "has_upstream": .bool(info.hasUpstream),
        ]
        if info.hasBase {
            members["base_ahead"] = .int(info.baseAhead)
            members["base_behind"] = .int(info.baseBehind)
        }
        if let n = info.issueNumber { members["issue_number"] = .int(n) }
        if let n = info.prNumber { members["pr_number"] = .int(n) }
        if let u = info.issueURL { members["issue_url"] = .string(u.absoluteString) }
        if let u = info.prURL { members["pr_url"] = .string(u.absoluteString) }
        if let c = info.checks {
            members["checks"] = .object([
                "passing": .int(c.passing), "failing": .int(c.failing),
                "cancelled": .int(c.cancelled), "skipped": .int(c.skipped),
                "pending": .int(c.pending), "summary": .string(c.summaryText),
            ])
        }
        return .object(members)
    }
}
