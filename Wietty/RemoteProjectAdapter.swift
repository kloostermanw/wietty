import Foundation
import WiettyShared

/// The decoded remote state in the shape the local UI consumes.
struct DecodedRemoteWorkspaces: Equatable {
    var projects: [Project] = []
    var gitInfo: [UUID: GitInfo] = [:]
    var runStates: [UUID: ClaudeRunState] = [:]
    var attention: Set<UUID> = []
    var jobNames: [UUID: String] = [:]
}

/// Maps the package's `RemoteWorkspace` values onto the app's local types, so
/// `WorkspaceCardView` can render a remote workspace with the same code it uses for a
/// local one.
///
/// This adapter is the only place the placeholder `Project` exists, deliberately: it is
/// a local shim, not part of the protocol, and it must not leak into the shared package
/// or the iPad client.
enum RemoteProjectAdapter {
    static func decoded(_ workspaces: [RemoteWorkspace]) -> DecodedRemoteWorkspaces {
        var out = DecodedRemoteWorkspaces()
        for workspace in workspaces {
            var refs: [TerminalRef] = []
            for session in workspace.sessions {
                refs.append(TerminalRef(id: session.id, label: session.label,
                                        sessionId: session.sessionId,
                                        kind: kind(session.kind), slot: session.label))
                out.runStates[session.id] = session.isRunning ? .running : .exited
                if session.needsAttention { out.attention.insert(session.id) }
                if let job = session.jobName { out.jobNames[session.id] = job }
            }
            out.projects.append(project(id: workspace.id, name: workspace.name, terminals: refs))
            if let git = workspace.git { out.gitInfo[workspace.id] = gitInfo(from: git) }
        }
        return out
    }

    private static func kind(_ kind: RemoteSessionKind) -> TerminalKind {
        switch kind {
        case .terminal: return .terminal
        case .claude: return .claude
        }
    }

    // MARK: - Remote `Project` synthesis contract
    //
    // `WorkspaceCardView` is shared between local and remote workspaces, and it takes a
    // `Project`. A remote workspace has no local folder, so this builds a PLACEHOLDER
    // `Project`: `url` is a synthetic value ("/remote/<name>") that exists only to
    // satisfy `Project`'s stored `url` property and must NEVER be dereferenced (no
    // `FileManager` calls, no reading `isGitRepository`). There is no folder at that
    // path. `configName` carries the real display name (`Project.name` reads
    // `configName` first). Git status for a remote workspace comes from the separately
    // mapped `GitInfo`, never from anything derived off `url`.
    private static func project(id: UUID, name: String, terminals: [TerminalRef]) -> Project {
        Project(id: id, url: URL(fileURLWithPath: "/remote/\(name)"), terminals: terminals, configName: name)
    }

    private static func gitInfo(from git: RemoteGit) -> GitInfo {
        var info = GitInfo(branch: git.branch, behind: git.behind, ahead: git.ahead,
                           hasUpstream: git.hasUpstream,
                           issueNumber: git.issueNumber, prNumber: git.prNumber)
        if let base = git.base {
            info.baseAhead = base.ahead
            info.baseBehind = base.behind
            info.hasBase = true
        }
        info.issueURL = git.issueURL
        info.prURL = git.prURL
        if let checks = git.checks {
            info.checks = ChecksSummary(passing: checks.passing, failing: checks.failing,
                                        cancelled: checks.cancelled, skipped: checks.skipped,
                                        pending: checks.pending)
        }
        return info
    }
}
