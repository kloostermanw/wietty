import Testing
import Foundation
@testable import Wietty

@Suite struct GitDirWatcherTests {
    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Lays out a minimal `.git` with the paths the watcher observes and seeds
    /// an initial reflog so `.git/logs/HEAD` exists (and can be appended to).
    private func makeGitDir(in workspace: URL) throws {
        let git = workspace.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("logs"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true
        )
        try Data("0".utf8).write(to: git.appendingPathComponent("logs/HEAD"))
    }

    @Test func firesOnReflogAppend() async throws {
        let folder = tempFolder()
        try makeGitDir(in: folder)
        let box = Box()
        let watcher = GitDirWatcher(workspace: folder) { box.count += 1 }
        watcher.start()
        defer { watcher.stop() }

        // Give the sources a moment to arm, then append to the reflog the way a
        // commit/checkout does (HEAD movements append to `.git/logs/HEAD`).
        try await Task.sleep(nanoseconds: 200_000_000)
        let log = folder.appendingPathComponent(".git/logs/HEAD")
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        handle.write(Data("commit\n".utf8))
        try handle.close()

        // Poll for the (debounced) callback for up to ~2s.
        for _ in 0..<20 {
            if box.count > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(box.count > 0)
    }

    @Test func noopWhenGitMissing() async throws {
        let folder = tempFolder()   // plain dir, no `.git`
        let box = Box()
        let watcher = GitDirWatcher(workspace: folder) { box.count += 1 }
        watcher.start()             // must not crash
        defer { watcher.stop() }

        try await Task.sleep(nanoseconds: 200_000_000)
        try Data("x".utf8).write(to: folder.appendingPathComponent("file.txt"))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(box.count == 0)
    }

    private final class Box: @unchecked Sendable { var count = 0 }
}
