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
}
