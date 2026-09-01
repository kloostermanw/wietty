import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct RemoteSessionListTests {
    @Test func buildsWorkspaceAndSessionEntries() {
        var project = Project(url: URL(fileURLWithPath: "/tmp/demo"))
        project.terminals = [
            TerminalRef(label: "shell", sessionId: "sess-1", kind: .terminal, slot: "0"),
            TerminalRef(label: "agent", sessionId: "sess-2", kind: .claude, slot: "1"),
        ]
        let json = RemoteSessionList.json(projects: [project])
        #expect(json.count == 1)
        #expect(json[0]["workspace"] as? String == "demo")
        let sessions = json[0]["sessions"] as? [[String: Any]]
        #expect(sessions?.count == 2)
        #expect(sessions?[0]["id"] as? String == "sess-1")
        #expect(sessions?[1]["kind"] as? String == "claude")
    }

    /// A live agent-reported title is applied on top of the stored name, so a client
    /// listing sessions shows what this app's sidebar shows. Issue #60.
    @Test func sessionLabelReflectsTheLiveOverride() {
        var project = Project(url: URL(fileURLWithPath: "/tmp/demo"))
        let agent = TerminalRef(label: "Claude 1", sessionId: "sess-2", kind: .claude, slot: "Claude 1")
        project.terminals = [agent]

        let json = RemoteSessionList.json(projects: [project],
                                          liveLabels: [agent.id: "running tests"])
        let sessions = json[0]["sessions"] as? [[String: Any]]
        #expect(sessions?[0]["label"] as? String == "running tests")
    }
}
