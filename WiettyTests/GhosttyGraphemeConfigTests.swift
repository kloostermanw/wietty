import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The one Ghostty setting a terminal's screen model has to share with its surface,
/// read through libghostty itself.
///
/// `ghostty_config_get` exposes only some keys, and which ones is found by asking,
/// not by reading. These ask: a file that sets `grapheme-width-method` either way,
/// and one that does not mention it. Each configuration is built from that file
/// alone, so nothing here reads the Ghostty config of whoever runs the suite, and
/// no surface host is constructed.
@MainActor
@Suite struct GhosttyGraphemeConfigTests {
    private func config(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wietty-grapheme-\(UUID().uuidString).cfg")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func legacyTurnsGraphemeClusteringOff() throws {
        let url = try config("grapheme-width-method = legacy\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GhosttySurfaceHost.graphemeClustering(loading: url) == false)
    }

    @Test func unicodeKeepsGraphemeClusteringOn() throws {
        let url = try config("grapheme-width-method = unicode\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GhosttySurfaceHost.graphemeClustering(loading: url) == true)
    }

    /// libghostty's default, which is also what a file that is not there resolves to.
    @Test func aConfigThatSaysNothingKeepsGraphemeClusteringOn() throws {
        let url = try config("font-size = 13\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GhosttySurfaceHost.graphemeClustering(loading: url) == true)
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("wietty-grapheme-absent-\(UUID().uuidString).cfg")
        #expect(GhosttySurfaceHost.graphemeClustering(loading: absent) == true)
    }
}
