import Testing
import Foundation
@testable import Wietty

@Suite struct ProjectGitTests {
    private func makeTempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func folderWithoutDotGitIsNotGitRepository() {
        let folder = makeTempFolder()
        #expect(Project(url: folder).isGitRepository == false)
    }

    @Test func folderWithDotGitDirectoryIsGitRepository() throws {
        let folder = makeTempFolder()
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        #expect(Project(url: folder).isGitRepository == true)
    }

    @Test func folderWithDotGitFileIsGitRepository() throws {
        // Worktrees and submodules use a `.git` file rather than a directory.
        let folder = makeTempFolder()
        try "gitdir: /somewhere".write(
            to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        #expect(Project(url: folder).isGitRepository == true)
    }
}
