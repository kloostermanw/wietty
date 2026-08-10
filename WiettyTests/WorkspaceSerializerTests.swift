import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct WorkspaceSerializerTests {
    @Test func serializesGitInfoBuckets() {
        let info = GitInfo(branch: "feature/x", behind: 1, ahead: 2, hasUpstream: true,
                           issueNumber: 42, prNumber: 7,
                           checks: ChecksSummary(passing: 3, failing: 1, cancelled: 0, skipped: 0, pending: 2))
        let json = WorkspaceSerializer.git(info)
        guard case let .object(m) = json else { Issue.record("expected object"); return }
        #expect(m["branch"] == .string("feature/x"))
        #expect(m["ahead"] == .int(2))
        #expect(m["issue_number"] == .int(42))
        guard case let .object(checks)? = m["checks"] else { Issue.record("expected checks"); return }
        #expect(checks["failing"] == .int(1))
        #expect(checks["pending"] == .int(2))
    }

    @Test func serializesTerminal() {
        let ref = TerminalRef(label: "shell", sessionId: "s1", kind: .terminal, slot: "0")
        let json = WorkspaceSerializer.terminal(ref, projectId: UUID(), projectName: "demo",
                                                runState: .running, needsAttention: true, jobName: "vim")
        guard case let .object(m) = json else { Issue.record("expected object"); return }
        #expect(m["session_id"] == .string("s1"))
        #expect(m["kind"] == .string("terminal"))
        #expect(m["run_state"] == .string("running"))
        #expect(m["needs_attention"] == .bool(true))
        #expect(m["job_name"] == .string("vim"))
    }
}
