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
                                                displayLabel: ref.displayName,
                                                runState: .running, needsAttention: true, jobName: "vim")
        guard case let .object(m) = json else { Issue.record("expected object"); return }
        #expect(m["session_id"] == .string("s1"))
        #expect(m["kind"] == .string("terminal"))
        #expect(m["run_state"] == .string("running"))
        #expect(m["needs_attention"] == .bool(true))
        #expect(m["job_name"] == .string("vim"))
    }

    /// The wire label carries the composed display name, so the prefix shows on every
    /// client rather than only in this app's sidebar. See issue #37.
    @Test func terminalLabelCarriesThePrefix() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s1", kind: .claude, slot: "Claude 5",
                              prefix: "[default]")
        let json = WorkspaceSerializer.terminal(ref, projectId: UUID(), projectName: "demo",
                                                displayLabel: ref.displayName,
                                                runState: .running, needsAttention: false, jobName: nil)
        guard case let .object(m) = json else { Issue.record("expected object"); return }
        #expect(m["label"] == .string("[default] Claude 5"))
    }

    /// A live agent-reported title reaches the wire, so a client shows the same name
    /// this app's sidebar does rather than the stored base label. Issue #60.
    @Test func terminalLabelReflectsTheLiveOverride() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s1", kind: .claude, slot: "Claude 5")
        let json = WorkspaceSerializer.terminal(ref, projectId: UUID(), projectName: "demo",
                                                displayLabel: "running tests",
                                                runState: .running, needsAttention: false, jobName: nil)
        guard case let .object(m) = json else { Issue.record("expected object"); return }
        #expect(m["label"] == .string("running tests"))
    }
}
