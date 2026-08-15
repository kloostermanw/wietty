import Testing
import Foundation
@testable import Wietty

/// The `~/.config/wietty/config` file I/O, in isolation from any setting that lives
/// in it. Like `GhosttyOverrideFile`, it is the user's to read and edit, so a write
/// has to leave everything it did not manage exactly as it found it.
@Suite struct WiettyConfigFileTests {
    private func file() -> WiettyConfigFile { .temporary() }

    @Test func anAbsentFileReadsEmpty() {
        #expect(file().read().isEmpty)
    }

    @Test func writtenPairsReadBack() throws {
        let file = file()
        try file.write([("remote-port", "8080"), ("bell-sound", "Submarine")])
        let values = file.read()
        #expect(values["remote-port"] == "8080")
        #expect(values["bell-sound"] == "Submarine")
    }

    /// The first write has to create `~/.config/wietty`, which need not exist.
    @Test func theFirstWriteCreatesTheDirectory() throws {
        let file = file()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        try file.write([("remote-port", "8080")])
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    /// An empty value is a value, not an absent key: `agent.0.args =` means "no
    /// arguments", and reading it as nil would fall back to some default instead.
    @Test func anEmptyValueReadsBackAsEmptyNotNil() throws {
        let file = file()
        try file.write([("agent.0.args", "")])
        #expect(file.read()["agent.0.args"] == "")
    }

    /// The user's own comments and any key this write does not manage survive.
    @Test func commentsAndUnmanagedKeysSurviveAWrite() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "# mine\nmy-own-key = keep\nremote-port = 1\n"
            .write(to: file.url, atomically: true, encoding: .utf8)

        try file.write([("remote-port", "8080")])

        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("# mine"))
        #expect(text.contains("my-own-key = keep"))
        #expect(file.read()["remote-port"] == "8080")
    }

    /// A list that shrank drops its stale entries: rewriting one agent where the file
    /// held three must remove `agent.1.*` and `agent.2.*`, none of which appear in the
    /// new pairs. That is what `managedPrefixes` is for.
    @Test func aShrunkListLosesItsStaleIndexedKeys() throws {
        let file = file()
        try file.write([
            ("agent.0.name", "A"), ("agent.1.name", "B"), ("agent.2.name", "C"),
        ], managedPrefixes: ["agent."])

        try file.write([("agent.0.name", "A")], managedPrefixes: ["agent."])

        let values = file.read()
        #expect(values["agent.0.name"] == "A")
        #expect(values["agent.1.name"] == nil)
        #expect(values["agent.2.name"] == nil)
    }

    /// A managed key the new write omits is removed even without a prefix, so a
    /// setting that went back to its default does not linger in the file.
    @Test func anOmittedManagedKeyIsRemoved() throws {
        let file = file()
        try file.write([("remote-port", "8080"), ("mcp-port", "3900")],
                       managedKeys: ["remote-port", "mcp-port"])

        try file.write([("mcp-port", "3900")], managedKeys: ["remote-port", "mcp-port"])

        let values = file.read()
        #expect(values["remote-port"] == nil)
        #expect(values["mcp-port"] == "3900")
    }

    /// A key set twice by hand resolves to the last one, matching how the format is
    /// read everywhere else.
    @Test func aKeySetTwiceResolvesToTheLast() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "remote-port = 1\nremote-port = 2\n".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(file.read()["remote-port"] == "2")
    }

    /// Repeated writes of the same content must not grow the file.
    @Test func repeatedIdenticalWritesDoNotGrowTheFile() throws {
        let file = file()
        try file.write([("remote-port", "8080")], managedKeys: ["remote-port"])
        let afterOne = try String(contentsOf: file.url, encoding: .utf8)
        for _ in 0..<5 {
            try file.write([("remote-port", "8080")], managedKeys: ["remote-port"])
        }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == afterOne)
    }
}

extension WiettyConfigFile {
    /// A file under a directory that does not exist yet, so a test covers the
    /// creating-it path the real first write takes.
    static func temporary() -> WiettyConfigFile {
        WiettyConfigFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/config"))
    }
}
