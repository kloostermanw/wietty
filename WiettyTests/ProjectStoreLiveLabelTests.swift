import Testing
import Foundation
import Observation
@testable import Wietty

/// A reference flag the `@Sendable` `withObservationTracking` onChange closure can
/// set. The store mutates on the main actor and the callback runs synchronously on
/// that same thread, so the unchecked bit is safe here.
private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}

/// Live agent-reported titles and the `.job` change-guard (issue #60).
///
/// The point of both is the same: keep a busy agent's constant retitling and the
/// 15s job poll from mutating the model, because every such mutation re-renders the
/// sidebar and dismisses an open workspace-card context menu. Titles land in
/// `liveLabels` (display-only, ephemeral) rather than the persisted `label`, and the
/// `.job` write is guarded so an unchanged name is not an `@Observable` notification.
@MainActor
@Suite struct ProjectStoreLiveLabelTests {
    private let storageKey = "wietty.projects.bookmarks"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.livelabel.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The persisted shape of a workspace, matching `ProjectStore.StoredProject`.
    private struct SeededProject: Codable {
        var id: UUID
        var bookmark: Data
        var terminals: [TerminalRef]
        var terminalSeq: Int
        var claudeSeq: Int
        var windowId: String?
        var collapsed: Bool
    }

    private func seedProject(_ defaults: UserDefaults, terminals: [TerminalRef]) {
        let folder = makeTempFolder(named: "proj-\(UUID().uuidString)")
        var records = (defaults.array(forKey: storageKey) as? [Data]) ?? []
        let record = SeededProject(id: UUID(), bookmark: try! folder.bookmarkData(),
                                    terminals: terminals, terminalSeq: terminals.count,
                                    claudeSeq: 0, windowId: nil, collapsed: false)
        records.append(try! JSONEncoder().encode(record))
        defaults.set(records, forKey: storageKey)
    }

    private func makeStore(terminals: [TerminalRef]) -> (ProjectStore, UserDefaults) {
        let defaults = makeDefaults()
        seedProject(defaults, terminals: terminals)
        return (ProjectStore(defaults: defaults, service: FakeTerminalService()), defaults)
    }

    // MARK: Titles land in liveLabels, not the model

    @Test func titleWritesTheLiveOverrideNotTheStoredLabel() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        let ref = store.projects[0].terminals[0]

        store.handle(.title(sessionId: "sess-A", name: "running tests"))

        #expect(store.liveLabels[ref.id] == "running tests")
        // The persisted name is untouched: the override is display-only.
        #expect(store.projects[0].terminals[0].label == "Claude 1")
        #expect(store.displayName(for: store.projects[0].terminals[0]) == "running tests")
    }

    /// The override is ephemeral and never written to disk: a fresh store reloaded
    /// from the same defaults carries the base label and no override.
    @Test func titleIsNotPersisted() {
        let (store, defaults) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.title(sessionId: "sess-A", name: "running tests"))

        let reloaded = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(reloaded.projects[0].terminals[0].label == "Claude 1")
        #expect(reloaded.liveLabels.isEmpty)
    }

    // MARK: The eligibility guards

    @Test func titleForAFixedNamingRowIsIgnored() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude,
                        slot: "Claude 1", fixedNaming: true),
        ])
        store.handle(.title(sessionId: "sess-A", name: "running tests"))
        #expect(store.liveLabels.isEmpty)
    }

    @Test func titleForANonClaudeRowIsIgnored() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Terminal 1", sessionId: "sess-A", kind: .terminal),
        ])
        store.handle(.title(sessionId: "sess-A", name: "vim"))
        #expect(store.liveLabels.isEmpty)
    }

    @Test func anEmptyTitleIsIgnored() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.title(sessionId: "sess-A", name: ""))
        #expect(store.liveLabels.isEmpty)
    }

    /// A title equal to the row's stored label is not an override worth holding: the
    /// display is the same either way, so nothing is written and nothing re-renders.
    @Test func aTitleEqualToTheStoredLabelWritesNothing() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.title(sessionId: "sess-A", name: "Claude 1"))
        #expect(store.liveLabels.isEmpty)
    }

    /// A title equal to the workspace badge is the badge coming back, not a reported
    /// title, so it is ignored the same way the old handler ignored it.
    @Test func aTitleEqualToTheWorkspaceNameIsIgnored() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        let workspaceName = store.projects[0].name
        store.handle(.title(sessionId: "sess-A", name: workspaceName))
        #expect(store.liveLabels.isEmpty)
    }

    /// Once an override is set, a later title equal to the base label drops it so the
    /// row recovers to its configured name rather than showing a stale title forever.
    /// The old handler got this for free by overwriting `label` directly. Issue #60.
    @Test func aTitleReturningToTheBaseLabelClearsTheOverride() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.title(sessionId: "sess-A", name: "running tests"))
        #expect(store.displayName(for: store.projects[0].terminals[0]) == "running tests")

        store.handle(.title(sessionId: "sess-A", name: "Claude 1"))
        #expect(store.liveLabels[store.projects[0].terminals[0].id] == nil)
        #expect(store.displayName(for: store.projects[0].terminals[0]) == "Claude 1")
    }

    // MARK: Rename clears the override

    /// A deliberate rename shows at once rather than being masked by a stale live
    /// title, so the override is dropped when the row is renamed by hand.
    @Test func renameClearsTheLiveOverride() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.title(sessionId: "sess-A", name: "running tests"))
        let ref = store.projects[0].terminals[0]

        store.rename(ref, in: store.projects[0], to: "my agent")

        #expect(store.liveLabels[ref.id] == nil)
        #expect(store.displayName(for: store.projects[0].terminals[0]) == "my agent")
    }

    // MARK: The .job change-guard

    /// An unchanged job name is not written, so `@Observable` does not notify and the
    /// 15s poll stops re-rendering (and dismissing) every open card menu.
    @Test func anUnchangedJobDoesNotNotify() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.job(sessionId: "sess-A", jobName: "node"))

        let flag = ChangeFlag()
        withObservationTracking { _ = store.jobNames } onChange: { flag.fired = true }
        store.handle(.job(sessionId: "sess-A", jobName: "node"))
        #expect(flag.fired == false)
    }

    @Test func aChangedJobDoesNotify() {
        let (store, _) = makeStore(terminals: [
            TerminalRef(label: "Claude 1", sessionId: "sess-A", kind: .claude),
        ])
        store.handle(.job(sessionId: "sess-A", jobName: "node"))

        let flag = ChangeFlag()
        withObservationTracking { _ = store.jobNames } onChange: { flag.fired = true }
        store.handle(.job(sessionId: "sess-A", jobName: "vim"))
        #expect(flag.fired == true)
    }
}
