import Testing
import Foundation
@testable import Wietty

/// The store the settings page and the popup read: the templates in memory, and the
/// add/update/remove that keep the `.md` files and the in-memory list in step.
@Suite @MainActor struct PromptTemplateStoreTests {
    private func store() -> PromptTemplateStore {
        PromptTemplateStore(file: .temporary())
    }

    @Test func aFreshStoreWithNoDirectoryIsEmpty() {
        #expect(store().templates.isEmpty)
    }

    @Test func addPutsATemplateInMemoryAndOnDisk() throws {
        let store = store()
        store.add(name: "Fix bug", summary: "Investigate", argumentHint: "<ticket>",
                  body: "Investigate bug $1.")

        #expect(store.templates.map(\.name) == ["Fix bug"])
        // A second store over the same directory sees it, so it really reached disk.
        let reloaded = PromptTemplateStore(file: store.file)
        #expect(reloaded.templates.map(\.name) == ["Fix bug"])
    }

    @Test func templatesStaySortedByName() {
        let store = store()
        store.add(name: "zebra", summary: "", argumentHint: "", body: "b")
        store.add(name: "Apple", summary: "", argumentHint: "", body: "b")
        #expect(store.templates.map(\.name) == ["Apple", "zebra"])
    }

    @Test func updateChangesATemplateInPlace() throws {
        let store = store()
        store.add(name: "Fix bug", summary: "", argumentHint: "", body: "First.")
        var edited = try #require(store.templates.first)
        edited.body = "Second."
        store.update(edited)

        #expect(store.templates.count == 1)
        #expect(store.templates.first?.body == "Second.")
    }

    @Test func removeDeletesTheTemplate() throws {
        let store = store()
        store.add(name: "Fix bug", summary: "", argumentHint: "", body: "Body.")
        store.remove(try #require(store.templates.first))
        #expect(store.templates.isEmpty)
    }

    @Test func reloadPicksUpAFileWrittenOutsideTheStore() throws {
        let store = store()
        #expect(store.templates.isEmpty)
        try FileManager.default.createDirectory(at: store.file.directory,
                                                withIntermediateDirectories: true)
        try "Body.".write(to: store.file.directory.appendingPathComponent("hand-made.md"),
                          atomically: true, encoding: .utf8)

        store.reload()
        #expect(store.templates.map(\.name) == ["hand-made"])
    }

    /// A file that cannot be read surfaces as `lastError` rather than vanishing, and a
    /// later clean reload clears it, so a fixed file does not leave the warning behind.
    @Test func reloadReportsAnUnreadableFileThenClearsWhenGone() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.file.directory,
                                                withIntermediateDirectories: true)
        let broken = store.file.directory.appendingPathComponent("broken.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: broken)

        store.reload()
        #expect(store.lastError != nil)

        try FileManager.default.removeItem(at: broken)
        store.reload()
        #expect(store.lastError == nil)
    }
}
