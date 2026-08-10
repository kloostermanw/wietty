import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct ProjectStoreChangesTests {
    private func makeStore() -> ProjectStore {
        ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                     service: FakeTerminalService(), gitProvider: RecordingProviderStub())
    }
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func yieldsWhenProjectsChange() async {
        let store = makeStore()
        let (id, stream) = store.workspaceChanges()
        defer { store.cancelWorkspaceChanges(id) }
        var iterator = stream.makeAsyncIterator()
        store.addProject(url: tempDir())          // mutate a tracked property
        let value: Void? = await iterator.next()
        #expect(value != nil)
    }

    @Test func broadcastsToAllSubscribers() async {
        let store = makeStore()
        let (idA, streamA) = store.workspaceChanges()
        let (idB, streamB) = store.workspaceChanges()
        defer {
            store.cancelWorkspaceChanges(idA)
            store.cancelWorkspaceChanges(idB)
        }
        var iteratorA = streamA.makeAsyncIterator()
        var iteratorB = streamB.makeAsyncIterator()
        store.addProject(url: tempDir())          // mutate a tracked property
        let valueA: Void? = await iteratorA.next()
        let valueB: Void? = await iteratorB.next()
        #expect(valueA != nil)
        #expect(valueB != nil)
    }

    @Test func rearmsAcrossSuccessiveChanges() async {
        let store = makeStore()
        let (id, stream) = store.workspaceChanges()
        defer { store.cancelWorkspaceChanges(id) }
        var iterator = stream.makeAsyncIterator()

        store.addProject(url: tempDir())
        let first: Void? = await iterator.next()
        #expect(first != nil)

        store.addProject(url: tempDir())
        let second: Void? = await iterator.next()
        #expect(second != nil)
    }

    @Test func cancelStopsDelivery() async {
        let store = makeStore()
        let (id, stream) = store.workspaceChanges()
        var iterator = stream.makeAsyncIterator()
        store.cancelWorkspaceChanges(id)
        let value: Void? = await iterator.next()
        #expect(value == nil)
    }
}

// Minimal provider so the store can be built.
final class RecordingProviderStub: GitInfoProviding, @unchecked Sendable {
    func gitSync(for folder: URL) async -> GitSync? { nil }
    func pullRequestNumber(for folder: URL, branch: String) async -> Int? { nil }
    func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? { nil }
}
