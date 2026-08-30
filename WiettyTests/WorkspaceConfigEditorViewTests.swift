import Testing
import Foundation
import SwiftUI
@testable import Wietty

/// The Edit workspace page grows a config editor when sync is on. These render the
/// page in both sync states and every new row in both its reading and editing
/// halves, so a wiring crash surfaces here rather than the first time it is opened,
/// the same reason `WorkspacePaneTests` renders the group picker.
@MainActor
@Suite struct WorkspaceConfigEditorViewTests {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "test.\(UUID().uuidString)")! }

    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("ws")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every new section title is a fact about the screen, asserted rather than only
    /// visible on opening it, the convention `WorkspacePaneTests` follows.
    @Test func theSectionTitlesArePresent() {
        #expect(!WorkspaceSettingsView.shellInitSectionTitle.isEmpty)
        #expect(!WorkspaceSettingsView.agentsSectionTitle.isEmpty)
        #expect(!WorkspaceSettingsView.terminalsSectionTitle.isEmpty)
        #expect(!WorkspaceSettingsView.processesSectionTitle.isEmpty)
        #expect(!WorkspaceSettingsView.testsSectionTitle.isEmpty)
        #expect(!WorkspaceSettingsView.enableSyncTitle.isEmpty)
    }

    /// Sync off: the page shows the enable button rather than empty editors.
    @Test func thePageRendersWithSyncOff() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let project = Project(url: URL(fileURLWithPath: "/tmp/no-config"))
        let view = WorkspaceSettingsView(store: store, project: project)
        #expect(ImageRenderer(content: view.frame(width: 600, height: 800)).nsImage != nil)
    }

    /// Sync on: every config section renders against a real, reconciled workspace.
    @Test func thePageRendersEverySectionWithSyncOn() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder()
        _ = try ConfigFile.write(WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "Claude 1", type: "claude")],
            terminals: ["Terminal 1"],
            processes: ["web": ProcessConfig(command: "npm run dev")],
            tests: ["unit": TestConfig(command: "phpunit")],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        ), in: folder)
        store.addProject(url: folder)
        store.approvePendingConfig()
        let project = try #require(store.projects.first)
        let view = WorkspaceSettingsView(store: store, project: project)
        #expect(ImageRenderer(content: view.frame(width: 600, height: 1400)).nsImage != nil)
    }

    /// Sync on but every list empty: each section auto-shows its add form (there is
    /// nothing to do but add the first item), the branch the section-with-items test
    /// does not reach.
    @Test func thePageRendersEmptyListsWithTheirAddFormsShown() throws {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        let folder = makeTempFolder()
        _ = try ConfigFile.write(WorkspaceConfig(name: nil, agents: [], terminals: []), in: folder)
        store.addProject(url: folder)
        store.approvePendingConfig()
        let project = try #require(store.projects.first)
        let view = WorkspaceSettingsView(store: store, project: project)
        #expect(ImageRenderer(content: view.frame(width: 600, height: 1200)).nsImage != nil)
    }

    // MARK: rows in both states

    private func render(_ view: some View) -> Bool {
        ImageRenderer(content: view.frame(width: 500, height: 700)).nsImage != nil
    }

    @Test func agentRowRendersBothStates() {
        let ref = TerminalRef(label: "a", sessionId: "", kind: .claude, slot: "a", command: "claude")
        #expect(render(AgentConfigRow(ref: ref, onSave: { _, _, _, _ in true }, onDelete: {})))
        #expect(render(AgentConfigRow(ref: ref, isEditing: true, onSave: { _, _, _, _ in true }, onDelete: {})))
        // A running agent row disables the type field; render that branch too.
        let live = TerminalRef(label: "a", sessionId: "live", kind: .claude, slot: "a", command: "claude")
        #expect(render(AgentConfigRow(ref: live, isEditing: true, onSave: { _, _, _, _ in true }, onDelete: {})))
    }

    @Test func terminalRowRendersBothStates() {
        let ref = TerminalRef(label: "Terminal 1", sessionId: "", kind: .terminal, slot: "Terminal 1")
        #expect(render(TerminalConfigRow(ref: ref, onSave: { _ in true }, onDelete: {})))
        #expect(render(TerminalConfigRow(ref: ref, isEditing: true, onSave: { _ in true }, onDelete: {})))
    }

    @Test func processRowRendersBothStates() {
        let config = ProcessConfig(command: "npm run dev", kind: .daemon, stop: "pkill node",
                                   env: ["FOO": "bar"], shellInit: ["nvm use 20"])
        #expect(render(ProcessConfigRow(name: "web", config: config, onSave: { _, _, _ in true }, onDelete: {})))
        #expect(render(ProcessConfigRow(name: "web", config: config, isEditing: true,
                                        onSave: { _, _, _ in true }, onDelete: {})))
    }

    @Test func testRowRendersBothStates() {
        let config = TestConfig(command: "phpunit", shellInit: ["source .venv/bin/activate"])
        #expect(render(TestConfigRow(name: "unit", config: config, onSave: { _, _, _ in true }, onDelete: {})))
        #expect(render(TestConfigRow(name: "unit", config: config, isEditing: true,
                                     onSave: { _, _, _ in true }, onDelete: {})))
    }

    @Test func addFormsAndShellInitEditorRender() {
        #expect(render(AddAgentForm { _, _, _, _ in true }))
        #expect(render(AddTerminalForm { _ in true }))
        #expect(render(AddProcessForm { _, _ in true }))
        #expect(render(AddTestForm { _, _ in true }))
        #expect(render(ShellInitEditor(lines: ["export X=1"], onSave: { _ in })))
    }
}
