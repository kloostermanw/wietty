import Foundation

/// Reads and writes the workspace `wietty.json`. Wraps security-scoped
/// access so it works with the app's bookmarked folders and with plain URLs in
/// tests (where `startAccessingSecurityScopedResource` returns false).
///
/// Only this name is read. A workspace still holding the old `itermplex.json`
/// reads as a workspace with no config, deliberately: the rename is a clean
/// break, not a migration.
package enum ConfigFile {
    package static let fileName = "wietty.json"

    package static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    package static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: folder).path)
    }

    package static func read(in folder: URL) throws -> WorkspaceConfig? {
        let fileURL = url(in: folder)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try WorkspaceConfig.parse(try Data(contentsOf: fileURL))
    }

    @discardableResult
    package static func write(_ config: WorkspaceConfig, in folder: URL) throws -> Data {
        let fileURL = url(in: folder)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let data = try config.encoded()
        try data.write(to: fileURL, options: .atomic)
        return data
    }

    package static func rawData(in folder: URL) -> Data? {
        let fileURL = url(in: folder)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: fileURL)
    }
}
