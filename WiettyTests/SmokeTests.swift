import AppKit
import SwiftUI
import Testing
@testable import Wietty

@Suite struct SmokeTests {
    @Test func sanity() {
        #expect(1 + 1 == 2)
    }

    @MainActor
    @Test func workspaceCardViewRendersExpanded() {
        let result = renderWorkspaceCard(collapsed: false)
        #expect(result != nil)
    }

    @MainActor
    @Test func workspaceCardViewRendersCollapsed() {
        let result = renderWorkspaceCard(collapsed: true)
        #expect(result != nil)
    }

    /// Exercises the Issue/PR line's branch-name fallback: when `gitInfo` has a
    /// branch but no issue number, the card renders the branch as plain text.
    @MainActor
    @Test func workspaceCardViewRendersBranchFallback() {
        let gitInfo = GitInfo(
            branch: "feature/issue-20",
            behind: 0,
            ahead: 0,
            hasUpstream: false,
            issueNumber: nil,
            prNumber: nil
        )
        let result = renderWorkspaceCard(collapsed: false, gitInfo: gitInfo)
        #expect(result != nil)
    }

    /// Exercises the Issue/PR line's pill path: when `gitInfo` carries an issue and
    /// PR number, the card renders the filled pills instead of the branch fallback.
    @MainActor
    @Test func workspaceCardViewRendersIssuePRPills() {
        let gitInfo = GitInfo(
            branch: "feature/issue-20",
            behind: 0,
            ahead: 0,
            hasUpstream: false,
            issueNumber: 20,
            prNumber: 21
        )
        let result = renderWorkspaceCard(collapsed: false, gitInfo: gitInfo)
        #expect(result != nil)
    }

    /// Builds a `WorkspaceCardView` with a real `Project` (with one terminal so the
    /// collapsible `children` section has content) and no-op callbacks, then forces
    /// an actual render pass via `ImageRenderer` so construction/wiring crashes in
    /// the whole view tree (including terminal rows) would surface here.
    @MainActor
    private func renderWorkspaceCard(collapsed: Bool, gitInfo: GitInfo? = nil) -> NSImage? {
        let project = Project(
            url: URL(fileURLWithPath: "/tmp/wietty-smoke-project"),
            terminals: [
                TerminalRef(label: "Terminal 1", sessionId: "sess-A", kind: .terminal)
            ],
            collapsed: collapsed
        )

        let view = WorkspaceCardView(
            project: project,
            collapsed: collapsed,
            gitInfo: gitInfo,
            runState: { _ in .running },
            needsAttention: { _ in false },
            syncEnabled: false,
            configChanged: false,
            isLocalOnly: { _ in false },
            onActivate: { _ in },
            onRestartTerminal: { _ in },
            onRenameTerminal: { _ in },
            onRemoveTerminal: { _ in },
            onCloseTerminal: { _ in },
            onOpenTerminal: {},
            onOpenClaude: {},
            onRemoveProject: {},
            onToggleCollapsed: {},
            onEnableSync: {},
            onApplyConfig: {},
            processes: [],
            onProcessStart: { _ in },
            onProcessStop: { _ in },
            onProcessRestart: { _ in },
            onProcessKill: { _ in },
            onOpenProcessLog: { _ in },
            tests: [],
            onTestRun: { _ in },
            onTestRunAll: {},
            onOpenTestLog: { _ in }
        )
        .frame(width: 320)

        let renderer = ImageRenderer(content: view)
        return renderer.nsImage
    }
}
