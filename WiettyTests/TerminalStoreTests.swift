import Testing
import Foundation
@testable import Wietty

private struct LegacyRef: Codable {
    var id: UUID
    var label: String
    var sessionId: String
}

private struct LegacyStored: Codable {
    var bookmark: Data
    var terminals: [LegacyRef]
    var terminalSeq: Int
    var windowId: String?
}

final class FakeTerminalService: TerminalService, @unchecked Sendable {
    var openCalls: [(folder: URL, existingWindowId: String?, command: String?, badge: String?)] = []
    var focusCalls: [String] = []
    var closeCalls: [String] = []
    var discardCalls: [String] = []
    /// Which of the two calls whose ORDER is a claim happened, in order: a row
    /// being reopened has to give up what the old session still held before its
    /// replacement is opened, or a substrate that keeps a dead terminal's surface
    /// leaks one per revival. Only those two are recorded, so this stays readable.
    var discardAndOpenOrder: [String] = []
    var handles: [TerminalHandle] = []
    var focusResult = FocusResult(found: true, jobName: nil)
    var sendCalls: [(sessionId: String, text: String)] = []
    var readOutputCalls: [(sessionId: String, maxLines: Int)] = []
    var readOutputResult = ""
    var errorToThrow: TerminalError?
    /// What `close` alone refuses with, for the paths where closing fails and
    /// opening does not. `errorToThrow` fails every call, which cannot model a
    /// restart that got as far as opening its replacement.
    var closeErrorToThrow: TerminalError?
    /// Awaited inside `open`, after the call is recorded and before the handle
    /// is produced, so a test can run other main actor work while an open is in
    /// flight. `TerminalService` is nonisolated, so the real `open` leaves the
    /// main actor for its whole duration and anything queued on it runs; without
    /// a gate this fake returns before the first suspension gives it the chance.
    /// Nil in every test that does not care.
    var openGate: (@MainActor () async -> Void)?
    private var openIndex = 0

    func open(folder: URL, existingWindowId: String?, command: String?, badge: String?) async throws -> TerminalHandle {
        if let error = errorToThrow { throw error }
        openCalls.append((folder, existingWindowId, command, badge))
        discardAndOpenOrder.append("open")
        await openGate?()
        let handle = openIndex < handles.count
            ? handles[openIndex]
            : TerminalHandle(sessionId: "sess-\(openIndex + 1)", windowId: "win-1")
        openIndex += 1
        return handle
    }

    func focus(sessionId: String) async throws -> FocusResult {
        if let error = errorToThrow { throw error }
        focusCalls.append(sessionId)
        return focusResult
    }

    func send(sessionId: String, text: String) async throws {
        if let error = errorToThrow { throw error }
        sendCalls.append((sessionId, text))
    }

    func close(sessionId: String) async throws {
        if let error = errorToThrow ?? closeErrorToThrow { throw error }
        closeCalls.append(sessionId)
    }

    func readOutput(sessionId: String, maxLines: Int) async throws -> String {
        if let error = errorToThrow { throw error }
        readOutputCalls.append((sessionId, maxLines))
        return readOutputResult
    }

    /// Recorded rather than inherited from the protocol's default, because the
    /// store's reopen path calling it at all is the claim.
    func discard(sessionId: String) async {
        discardCalls.append(sessionId)
        discardAndOpenOrder.append("discard")
    }
}

@Suite @MainActor struct TerminalStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func newProjectHasNoTerminals() {
        let project = Project(url: URL(fileURLWithPath: "/tmp/x"))
        #expect(project.terminals.isEmpty)
        #expect(project.windowId == nil)
        #expect(project.terminalSeq == 0)
        #expect(project.claudeSeq == 0)
    }

    @Test func decodesLegacyTerminalRefWithoutKind() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","label":"Terminal 1","sessionId":"sess-A"}
        """.utf8)
        let ref = try JSONDecoder().decode(TerminalRef.self, from: json)
        #expect(ref.kind == .terminal)
        #expect(ref.label == "Terminal 1")
        #expect(ref.sessionId == "sess-A")
    }

    @Test func encodesAndDecodesClaudeKind() throws {
        let ref = TerminalRef(label: "Claude 1", sessionId: "s", kind: .claude)
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(TerminalRef.self, from: data)
        #expect(decoded.kind == .claude)
    }

    @Test func openTerminalAppendsNumberedRefsAndTracksWindow() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openTerminal(for: store.projects[0])
        #expect(store.projects[0].terminals.map(\.label) == ["Terminal 1"])
        #expect(store.projects[0].terminals[0].sessionId == "sess-A")
        #expect(store.projects[0].windowId == "win-1")
        #expect(store.projects[0].terminalSeq == 1)

        await store.openTerminal(for: store.projects[0])
        #expect(store.projects[0].terminals.map(\.label) == ["Terminal 1", "Terminal 2"])
        #expect(fake.openCalls.count == 2)
        #expect(fake.openCalls[1].existingWindowId == "win-1")
    }

    @Test func openClaudeAppendsClaudeRefAndRunsClaude() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openClaude(for: store.projects[0])
        #expect(store.projects[0].terminals.map(\.label) == ["Claude 1"])
        #expect(store.projects[0].terminals[0].kind == .claude)
        #expect(store.projects[0].terminals[0].sessionId == "sess-A")
        #expect(store.projects[0].claudeSeq == 1)
        #expect(fake.openCalls.count == 1)
        // A plain shell, with `claude` typed into it. See
        // `aClaudeRowIsAShellWithClaudeTypedIntoIt` for why it is not the command.
        #expect(fake.openCalls[0].command == nil)
        #expect(fake.sendCalls.map(\.text) == ["claude\n"])
    }

    @Test func openTerminalPassesNilCommand() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openTerminal(for: store.projects[0])
        #expect(store.projects[0].terminals[0].kind == .terminal)
        #expect(fake.openCalls[0].command == nil)
    }

    @Test func terminalAndClaudeUseIndependentNumbering() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "s1", windowId: "win-1"),
            TerminalHandle(sessionId: "s2", windowId: "win-1"),
            TerminalHandle(sessionId: "s3", windowId: "win-1"),
            TerminalHandle(sessionId: "s4", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openTerminal(for: store.projects[0])
        await store.openClaude(for: store.projects[0])
        await store.openTerminal(for: store.projects[0])
        await store.openClaude(for: store.projects[0])
        #expect(store.projects[0].terminals.map(\.label)
            == ["Terminal 1", "Claude 1", "Terminal 2", "Claude 2"])
    }

    @Test func terminalsPersistAcrossStoreInstances() async {
        let defaults = makeDefaults()
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store1 = ProjectStore(defaults: defaults, service: fake)
        store1.addProject(url: makeTempFolder(named: "proj"))
        await store1.openTerminal(for: store1.projects[0])

        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects.count == 1)
        #expect(store2.projects[0].terminals.map(\.label) == ["Terminal 1"])
        #expect(store2.projects[0].terminals[0].sessionId == "sess-A")
        #expect(store2.projects[0].windowId == "win-1")
        #expect(store2.projects[0].terminalSeq == 1)
    }

    @Test func failedOpenSetsLastErrorAndLeavesModelUnchanged() async {
        let fake = FakeTerminalService()
        fake.errorToThrow = .failed("boom")
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openTerminal(for: store.projects[0])
        #expect(store.projects[0].terminals.isEmpty)
        #expect(store.lastError == TerminalError.failed("boom").errorDescription)
    }

    @Test func activateLiveSessionOnlyFocuses() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        fake.focusResult = FocusResult(found: true, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.focusCalls == ["sess-A"])
        #expect(fake.openCalls.count == 1) // no reopen
    }

    @Test func activateDeadSessionReopensAndRebinds() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-2"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        fake.focusResult = FocusResult(found: false, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.focusCalls == ["sess-A"])
        #expect(fake.openCalls.count == 2)
        #expect(store.projects[0].terminals[0].sessionId == "sess-B")
        #expect(store.projects[0].windowId == "win-2")
        #expect(store.projects[0].terminals[0].label == "Terminal 1") // label unchanged
    }

    @Test func activateClaudeInShellRestartsClaude() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        // Opening the row already typed `claude` once, so the revival is counted
        // from here rather than from zero.
        let sendsAfterOpening = fake.sendCalls.count
        fake.focusResult = FocusResult(found: true, jobName: "zsh")
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.sendCalls.count == sendsAfterOpening + 1)
        #expect(fake.sendCalls.last! == ("sess-A", "claude\n"))
        #expect(fake.openCalls.count == 1) // no reopen; session was alive
    }

    @Test func activateClaudeWhileRunningDoesNotRestart() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        let sendsAfterOpening = fake.sendCalls.count
        fake.focusResult = FocusResult(found: true, jobName: "2.1.203") // claude version
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.sendCalls.count == sendsAfterOpening)
    }

    @Test func activateClaudeWithNilJobRestarts() async {
        // Bare shell reports jobName == nil (no shell integration); treat as exited.
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        let sendsAfterOpening = fake.sendCalls.count
        fake.focusResult = FocusResult(found: true, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.sendCalls.count == sendsAfterOpening + 1)
        #expect(fake.sendCalls.last! == ("sess-A", "claude\n"))
    }

    @Test func activateDeadClaudeReopensRunningClaude() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        let sendsAfterOpening = fake.sendCalls.count
        fake.focusResult = FocusResult(found: false, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.openCalls.count == 2)
        // A shell again, with the agent typed into it. Clicking a row whose
        // terminal is gone is the COMMON way an agent row starts, far more common
        // than creating one, so this path failing is what a user actually meets.
        #expect(fake.openCalls[1].command == nil)
        #expect(fake.sendCalls.count == sendsAfterOpening + 1)
        #expect(fake.sendCalls.last! == ("sess-B", "claude\n"))
        #expect(store.projects[0].terminals[0].sessionId == "sess-B")
    }

    /// Restarting an agent row goes the same way as opening and reopening one. It
    /// is the third door into the same room, and it was the last one still handing
    /// the agent to the shell as its command.
    @Test func restartingAnAgentRowTypesItIntoAFreshShell() async throws {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let sendsAfterOpening = fake.sendCalls.count

        _ = try await store.restart(sessionId: "sess-A")

        #expect(fake.openCalls.last?.command == nil)
        #expect(fake.sendCalls.count == sendsAfterOpening + 1)
        #expect(fake.sendCalls.last! == ("sess-B", "claude\n"))
    }

    /// A row can go away while its replacement is opening, when its workspace is
    /// removed. Nothing will ever point at the shell that just opened, so it is closed
    /// rather than left running with no way to reach it.
    @Test func aRestartWhoseRowVanishesClosesTheShellItOpened() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        // Pulls the row out from under the restart, after the replacement has been
        // opened and before the store looks for the row to point at it.
        fake.openGate = { store.remove(store.projects[0]) }
        await store.restartTerminal(sessionId: "sess-A")

        #expect(store.lastError == "No tracked terminal has that session id.")
        #expect(fake.closeCalls.contains("sess-B"))
    }

    /// A restart that cannot stop the old session has not restarted anything. Going
    /// on to open the replacement and repointing the row at it left the previous
    /// agent running, holding its pty and still able to write to the folder, with
    /// nothing referencing it and the restart reporting success.
    @Test func aRestartThatCannotCloseTheOldSessionFails() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])
        let opensAfterOpening = fake.openCalls.count

        fake.closeErrorToThrow = .failed("still running")
        await store.restartTerminal(sessionId: "sess-A")

        #expect(store.lastError == "still running")
        // No replacement was opened, so there is no second session to orphan, and the
        // row still points at the one that is genuinely running.
        #expect(fake.openCalls.count == opensAfterOpening)
        #expect(store.projects[0].terminals[0].sessionId == "sess-A")
    }

    /// A restart the sidebar asked for reports its failure the way every other row
    /// action does, through the alert. `restart(sessionId:)` throws instead, because
    /// the MCP server and the remote server turn that error into a response for the
    /// caller that asked; a click has no caller to answer, so the window's own entry
    /// point is the one that reports.
    @Test func aFailedRestartFromTheSidebarSetsLastError() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        fake.errorToThrow = .failed("boom")
        await store.restartTerminal(sessionId: "sess-A")

        #expect(store.lastError == "boom")
        // The row survives a restart that could not open the replacement, so there
        // is still something to click once whatever broke is fixed.
        #expect(store.projects[0].terminals.count == 1)
    }

    /// The unknown session is the case a stale click produces: the row's terminal is
    /// gone from under it. It has to reach the alert too, rather than being swallowed
    /// as "nothing to restart".
    @Test func restartingAnUnknownSessionFromTheSidebarSetsLastError() async {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())

        await store.restartTerminal(sessionId: "sess-gone")

        #expect(store.lastError == StoreError.unknownSession.errorDescription)
    }

    @Test func activateDeadTerminalReopensPlainShell() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        fake.focusResult = FocusResult(found: false, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.openCalls.count == 2)
        #expect(fake.openCalls[1].command == nil)
    }

    @Test func renameChangesLabelAndPersists() async {
        let defaults = makeDefaults()
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store1 = ProjectStore(defaults: defaults, service: fake)
        store1.addProject(url: makeTempFolder(named: "proj"))
        await store1.openTerminal(for: store1.projects[0])

        store1.rename(store1.projects[0].terminals[0], in: store1.projects[0], to: "server")
        #expect(store1.projects[0].terminals[0].label == "server")

        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.projects[0].terminals[0].label == "server")
    }

    @Test func removeTerminalForgetsWithoutClosing() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        store.removeTerminal(store.projects[0].terminals[0], in: store.projects[0])
        #expect(store.projects[0].terminals.isEmpty)
        #expect(fake.closeCalls.isEmpty)
    }

    @Test func closeTerminalClosesSessionThenForgets() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        await store.closeTerminal(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.closeCalls == ["sess-A"])
        #expect(store.projects[0].terminals.isEmpty)
    }

    @Test func closeTerminalFailureKeepsRef() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        fake.errorToThrow = .failed("boom")
        await store.closeTerminal(store.projects[0].terminals[0], in: store.projects[0])
        #expect(store.projects[0].terminals.count == 1)
        #expect(store.lastError == "boom")
    }

    @Test func renameToNonEmptyLabelUpdatesRef() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])
        store.rename(store.projects[0].terminals[0], in: store.projects[0], to: "api")
        #expect(store.projects[0].terminals[0].label == "api")
    }

    @Test func loadsLegacyProjectWithoutClaudeSeqOrKind() throws {
        let defaults = makeDefaults()
        let folder = makeTempFolder(named: "proj")
        let bookmark = try folder.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let legacy = LegacyStored(
            bookmark: bookmark,
            terminals: [LegacyRef(id: UUID(), label: "Terminal 1", sessionId: "sess-A")],
            terminalSeq: 1,
            windowId: "win-1"
        )
        let data = try JSONEncoder().encode(legacy)
        // Storage key is private to ProjectStore; kept in sync intentionally.
        defaults.set([data], forKey: "wietty.projects.bookmarks")

        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store.projects.count == 1)
        #expect(store.projects[0].terminals.map(\.label) == ["Terminal 1"])
        #expect(store.projects[0].terminals[0].kind == .terminal)
        #expect(store.projects[0].terminalSeq == 1)
        #expect(store.projects[0].claudeSeq == 0)
        #expect(store.projects[0].collapsed == false)
    }

    @Test func titleEventUpdatesClaudeLabel() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        store.handle(.title(sessionId: "sess-A", name: "refactor parser"))
        #expect(store.projects[0].terminals[0].label == "refactor parser")
    }

    @Test func titleEventIgnoredForTerminalKind() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        store.handle(.title(sessionId: "sess-A", name: "should not apply"))
        #expect(store.projects[0].terminals[0].label == "Terminal 1")
    }

    @Test func titleEventForUnknownSessionIgnored() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        store.handle(.title(sessionId: "nope", name: "x"))
        #expect(store.projects[0].terminals[0].label == "Claude 1")
    }

    @Test func bellEventAddsAttentionAndActivateClears() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        fake.focusResult = FocusResult(found: true, jobName: "node")
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        store.handle(.bell(sessionId: "sess-A"))
        #expect(store.attention.contains(ref.id))

        await store.activate(ref, in: store.projects[0])
        #expect(!store.attention.contains(ref.id))
    }

    @Test func jobEventDrivesRunState() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        #expect(store.runState(for: ref) == .running) // no info yet -> optimistic
        store.handle(.job(sessionId: "sess-A", jobName: "2.1.203")) // claude version string
        #expect(store.runState(for: ref) == .running)
        store.handle(.job(sessionId: "sess-A", jobName: "zsh"))
        #expect(store.runState(for: ref) == .exited)
        store.handle(.job(sessionId: "sess-A", jobName: "")) // bare shell, no shell integration
        #expect(store.runState(for: ref) == .exited)
    }

    @Test func titleEventWithUnchangedNameSkipsUpdateButLaterChangeApplies() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        store.handle(.title(sessionId: "sess-A", name: "Claude 1"))
        #expect(store.projects[0].terminals[0].label == "Claude 1")

        store.handle(.title(sessionId: "sess-A", name: "refactor parser"))
        #expect(store.projects[0].terminals[0].label == "refactor parser")
    }

    @Test func removeTerminalPurgesAttentionAndJobNames() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])

        store.handle(.bell(sessionId: "sess-A"))
        store.handle(.job(sessionId: "sess-A", jobName: "zsh"))
        let ref = store.projects[0].terminals[0]
        #expect(store.attention.contains(ref.id))
        #expect(store.runState(for: ref) == .exited)

        store.removeTerminal(ref, in: store.projects[0])
        #expect(!store.attention.contains(ref.id))
        #expect(store.runState(for: ref) == .running) // jobNames entry purged -> optimistic default
    }

    @Test func workspaceBadgeSettingDefaultsOff() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService())
        #expect(store.showWorkspaceBadge == false)
    }

    @Test func openPassesNilBadgeWhenSettingOff() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openTerminal(for: store.projects[0])
        #expect(fake.openCalls[0].badge == nil)
    }

    @Test func openPassesWorkspaceNameAsBadgeWhenSettingOn() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.showWorkspaceBadge = true
        store.addProject(url: makeTempFolder(named: "acme-api"))

        await store.openClaude(for: store.projects[0])
        #expect(fake.openCalls[0].badge == "acme-api")
    }

    @Test func workspaceBadgeSettingPersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.showWorkspaceBadge = true

        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.showWorkspaceBadge == true)
    }

    @Test func titleEqualToWorkspaceBadgeIsIgnored() async {
        // With the badge setting on, `TmuxService.open` writes the workspace
        // name into `pane_title` via `select-pane -T`, and the poll reads that
        // straight back as a `.title` event carrying the same name.
        // Relabelling from it would flip the row from "Claude 1" to the
        // workspace name the instant the pane opens, before Claude ever sets
        // its own title.
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.showWorkspaceBadge = true
        store.addProject(url: makeTempFolder(named: "acme-api"))
        await store.openClaude(for: store.projects[0])

        store.handle(.title(sessionId: "sess-A", name: "acme-api"))
        #expect(store.projects[0].terminals[0].label == "Claude 1")
    }

    @Test func genuineTitleStillAppliesWithBadgeSettingOn() async {
        // A title that differs from the workspace badge is a real one (from
        // Claude's own OSC title) and must still relabel the row.
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.showWorkspaceBadge = true
        store.addProject(url: makeTempFolder(named: "acme-api"))
        await store.openClaude(for: store.projects[0])

        store.handle(.title(sessionId: "sess-A", name: "refactor parser"))
        #expect(store.projects[0].terminals[0].label == "refactor parser")
    }

    @Test func reopeningDeadSessionCarriesBadgeWhenSettingOn() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.showWorkspaceBadge = true
        store.addProject(url: makeTempFolder(named: "acme-api"))
        await store.openTerminal(for: store.projects[0])

        fake.focusResult = FocusResult(found: false, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.openCalls.count == 2)
        #expect(fake.openCalls[1].badge == "acme-api")
    }

    /// A row being reopened gives up what the service still held under the old id,
    /// and does it BEFORE the replacement is opened.
    ///
    /// The service keeps a dead terminal's libghostty surface and its `NSView` on
    /// purpose, so the last screen a command left stays readable, and this reopen is
    /// the one moment that
    /// screen is finished with. Without the call the row traded a dead terminal for a
    /// leaked surface on every revival, for the life of the process.
    @Test func reopeningARowDiscardsWhatTheServiceStillHeld() async {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "sess-A", windowId: "win-1"),
            TerminalHandle(sessionId: "sess-B", windowId: "win-1"),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        fake.focusResult = FocusResult(found: false, jobName: nil)
        await store.activate(store.projects[0].terminals[0], in: store.projects[0])
        #expect(fake.discardCalls == ["sess-A"])
        #expect(fake.discardAndOpenOrder == ["open", "discard", "open"])
    }

    /// A Claude row is a shell with `claude` typed into it, not a shell REPLACED by
    /// claude, and the difference is two bugs.
    ///
    /// Run as the shell's command (`zsh -l -c claude`) the shell is not
    /// interactive, so it never reads `.zshrc`, which is where a normal setup puts
    /// its PATH additions. `claude` was then not found, the child exited 127 within
    /// milliseconds, its relay socket was unlinked by the reap, and the surface's
    /// helper (started a few milliseconds later) reported "this terminal is gone".
    /// Typed into an interactive shell it is found, because that is the same shell
    /// the user gets in a terminal row.
    ///
    /// It also leaves something behind. A command that exits takes its pty with it
    /// and the row becomes a dead surface with nothing to click; a shell survives
    /// its command, so the row is a prompt again and can simply be used or
    /// restarted. `activate` already revives a stopped agent by typing `claude`
    /// into its shell, so this is the same model on both paths rather than two.
    @Test func aClaudeRowIsAShellWithClaudeTypedIntoIt() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "gt:a", windowId: "")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openClaude(for: store.projects[0])

        #expect(fake.openCalls.map(\.command) == [nil])
        #expect(fake.sendCalls.map(\.text) == ["claude\n"])
        #expect(store.projects[0].terminals.first?.kind == .claude)
    }

    /// A terminal row types nothing: its shell is the terminal.
    @Test func aTerminalRowOpensAPlainShell() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "gt:a", windowId: "")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))

        await store.openTerminal(for: store.projects[0])

        #expect(fake.openCalls.map(\.command) == [nil])
        #expect(fake.sendCalls.isEmpty)
    }

    /// "Remove" drops a row and closes the terminal it named.
    ///
    /// The row is the handle: the session id is recorded nowhere else, so dropping
    /// the row silently left a live shell, its pty, its socket file, its helper
    /// process and its surface running with nothing in the UI able to name any of
    /// them until the app quit.
    @Test func removingARowClosesATerminalOnlyThisAppCouldReach() async throws {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "gt:a", windowId: "")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])

        store.removeTerminal(store.projects[0].terminals[0], in: store.projects[0])
        #expect(store.projects[0].terminals.isEmpty)
        try await waitUntil { fake.closeCalls == ["gt:a"] }
    }

    /// Removing a whole workspace is the same hole, one row at a time, and the worse
    /// case of the two: it takes every terminal the workspace held at once.
    @Test func removingAWorkspaceClosesTerminalsOnlyThisAppCouldReach() async throws {
        let fake = FakeTerminalService()
        fake.handles = [
            TerminalHandle(sessionId: "gt:a", windowId: ""),
            TerminalHandle(sessionId: "gt:b", windowId: ""),
        ]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openTerminal(for: store.projects[0])
        await store.openTerminal(for: store.projects[0])

        store.remove(store.projects[0])
        #expect(store.projects.isEmpty)
        try await waitUntil { fake.closeCalls.sorted() == ["gt:a", "gt:b"] }
    }

    /// Polls rather than sleeping a fixed time: the close is deliberately fire and
    /// forget, because the row it belonged to is already gone from the sidebar.
    private func waitUntil(timeout: Duration = .seconds(3),
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Bool(false), "condition never became true")
    }

    @Test func terminatedEventMarksExitedAndKeepsRef() async {
        let fake = FakeTerminalService()
        fake.handles = [TerminalHandle(sessionId: "sess-A", windowId: "win-1")]
        let store = ProjectStore(defaults: makeDefaults(), service: fake)
        store.addProject(url: makeTempFolder(named: "proj"))
        await store.openClaude(for: store.projects[0])
        let ref = store.projects[0].terminals[0]

        store.handle(.terminated(sessionId: "sess-A"))
        #expect(store.runState(for: ref) == .exited)
        #expect(store.projects[0].terminals.count == 1)
    }
}
