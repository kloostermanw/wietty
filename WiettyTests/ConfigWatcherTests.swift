import Testing
import Foundation
@testable import Wietty

@Suite struct ConfigWatcherTests {
    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func firesOnFileWrite() async throws {
        let folder = tempFolder()
        let box = Box()
        let watcher = ConfigWatcher(folder: folder) { box.count += 1 }
        watcher.start()
        defer { watcher.stop() }

        // Give the source a moment to arm, then write the file.
        try await Task.sleep(nanoseconds: 200_000_000)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("wietty.json"))

        // Poll for the callback for up to ~2s.
        for _ in 0..<20 {
            if box.count > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(box.count > 0)
    }

    @Test func firesAfterRestart() async throws {
        let folder = tempFolder()
        let box = Box()
        let watcher = ConfigWatcher(folder: folder) { box.count += 1 }
        watcher.start()
        watcher.start()
        defer { watcher.stop() }

        // Give the source a moment to arm, then write the file.
        try await Task.sleep(nanoseconds: 200_000_000)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("wietty.json"))

        // Poll for the callback for up to ~2s.
        for _ in 0..<20 {
            if box.count > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(box.count > 0)
    }

    private final class Box: @unchecked Sendable { var count = 0 }
}
