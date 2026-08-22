import Testing
import Foundation
@testable import Wietty

/// The directory of `~/.config/wietty/prompt_templates/*.md` files: listing them,
/// writing one, deleting one, and naming a new file. Like `WiettyConfigFile`, these
/// are the user's files to read and edit, so listing tolerates hand-made and
/// malformed files rather than failing the lot.
@Suite struct PromptTemplateFileTests {
    private func store() -> PromptTemplateFile { .temporary() }

    private func template(name: String, summary: String = "", hint: String = "",
                          body: String, in file: PromptTemplateFile) -> PromptTemplate {
        PromptTemplate(name: name, summary: summary, argumentHint: hint, body: body,
                       fileURL: file.availableURL(forName: name))
    }

    @Test func anAbsentDirectoryListsEmpty() throws {
        #expect(try store().list().isEmpty)
    }

    @Test func aSavedTemplateReadsBack() throws {
        let file = store()
        let saved = template(name: "Fix bug", summary: "Investigate", hint: "<ticket>",
                             body: "Investigate bug $1.", in: file)
        try file.save(saved)

        let listed = try file.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "Fix bug")
        #expect(listed.first?.summary == "Investigate")
        #expect(listed.first?.argumentHint == "<ticket>")
        #expect(listed.first?.body == "Investigate bug $1.")
    }

    @Test func theFirstSaveCreatesTheDirectory() throws {
        let file = store()
        #expect(!FileManager.default.fileExists(atPath: file.directory.path))
        try file.save(template(name: "T", body: "Body.", in: file))
        #expect(FileManager.default.fileExists(atPath: file.directory.path))
    }

    @Test func listingIgnoresNonMarkdownFiles() throws {
        let file = store()
        try file.save(template(name: "Real", body: "Body.", in: file))
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        try "not a template".write(to: file.directory.appendingPathComponent("notes.txt"),
                                   atomically: true, encoding: .utf8)

        let listed = try file.list()
        #expect(listed.map(\.name) == ["Real"])
    }

    @Test func listingToleratesAFileWithNoFrontmatter() throws {
        let file = store()
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        try "Just a body.".write(to: file.directory.appendingPathComponent("hand-made.md"),
                                 atomically: true, encoding: .utf8)

        let listed = try file.list()
        #expect(listed.map(\.name) == ["hand-made"])
        #expect(listed.first?.body == "Just a body.")
    }

    @Test func listingIsSortedByDisplayNameCaseInsensitively() throws {
        let file = store()
        try file.save(template(name: "zebra", body: "b", in: file))
        try file.save(template(name: "Apple", body: "b", in: file))
        try file.save(template(name: "banana", body: "b", in: file))
        #expect(try file.list().map(\.name) == ["Apple", "banana", "zebra"])
    }

    @Test func savingReplacesTheSameFileRatherThanAddingASecond() throws {
        let file = store()
        var t = template(name: "Fix bug", body: "First.", in: file)
        try file.save(t)
        t.body = "Second."
        try file.save(t)

        let listed = try file.list()
        #expect(listed.count == 1)
        #expect(listed.first?.body == "Second.")
    }

    @Test func deleteRemovesTheFile() throws {
        let file = store()
        let t = template(name: "Fix bug", body: "Body.", in: file)
        try file.save(t)
        try file.delete(t)
        #expect(try file.list().isEmpty)
    }

    // MARK: Naming

    @Test func nameBecomesASluggedMarkdownFilename() {
        #expect(PromptTemplateFile.slug("Fix bug") == "fix-bug")
        #expect(PromptTemplateFile.slug("Refactor & Clean!") == "refactor-clean")
        #expect(PromptTemplateFile.slug("  spaced  out  ") == "spaced-out")
    }

    @Test func anEmptySlugFallsBackSoTheFileIsStillNamed() {
        #expect(PromptTemplateFile.slug("!!!") == "template")
    }

    @Test func aCollidingNameGetsASuffix() throws {
        let file = store()
        try file.save(template(name: "Fix bug", body: "One.", in: file))
        let second = file.availableURL(forName: "Fix bug")
        #expect(second.lastPathComponent == "fix-bug-2.md")
    }
}

extension PromptTemplateFile {
    /// A store under a directory that does not exist yet, so a test covers the
    /// creating-it path the real first save takes.
    static func temporary() -> PromptTemplateFile {
        PromptTemplateFile(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/prompt_templates"))
    }
}
