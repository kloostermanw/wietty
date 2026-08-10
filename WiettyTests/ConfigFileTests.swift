import Testing
import Foundation
@testable import Wietty

@Suite struct ConfigFileTests {
    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func existsIsFalseWhenNoFile() {
        #expect(ConfigFile.exists(in: tempFolder()) == false)
    }

    @Test func readReturnsNilWhenAbsent() throws {
        #expect(try ConfigFile.read(in: tempFolder()) == nil)
    }

    @Test func writeThenReadRoundTrips() throws {
        let folder = tempFolder()
        let config = WorkspaceConfig(
            name: "acme",
            agents: [.init(slot: "claude1", type: "claude")],
            terminals: ["Terminal 1"]
        )
        let written = try ConfigFile.write(config, in: folder)
        #expect(ConfigFile.exists(in: folder))
        #expect(try ConfigFile.read(in: folder) == config)
        #expect(ConfigFile.rawData(in: folder) == written)
    }

    @Test func writeUsesExactFileName() throws {
        let folder = tempFolder()
        try ConfigFile.write(WorkspaceConfig(name: nil, agents: [], terminals: []), in: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wietty.json").path))
    }

    /// The rename is a clean break: nothing reads the old filename, so a workspace
    /// still holding one reads as a workspace with no config at all rather than
    /// quietly picking it up.
    @Test func theOldFileNameIsNotRead() throws {
        let folder = tempFolder()
        let json = Data("""
        { "name": "acme", "agents": [], "terminals": ["Terminal 1"] }
        """.utf8)
        try json.write(to: folder.appendingPathComponent("itermplex.json"))

        #expect(ConfigFile.exists(in: folder) == false)
        #expect(try ConfigFile.read(in: folder) == nil)
    }
}
