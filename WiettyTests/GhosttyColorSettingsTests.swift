import Testing
import Foundation
import SwiftUI
@testable import Wietty

/// The Settings side of the terminal colours: what it reads from the override file,
/// what it writes there, and that a write reloads the live config so terminals
/// already open take the new colour rather than only the next launch's.
///
/// Unlike the notifications toggle, this shows the override file's own value rather
/// than libghostty's resolved one: a colour Wietty is forcing is what the file says,
/// and reading a resolved colour back from libghostty is a good deal more involved
/// than reading a boolean.
@MainActor
@Suite struct GhosttyColorSettingsTests {
    @Test func writingAColourReloadsTheLiveConfig() {
        let host = FakeSurfaceHost()
        let settings = GhosttyColorSettings(host: host, file: .temporary())
        settings.setColor(GhosttyOverrideFile.ColorKey.background, to: ColorHex.color(from: "#303446"))
        #expect(host.reloadCount == 1)
        #expect(settings.writeFailure == nil)
    }

    @Test func writingAColourWritesTheFile() throws {
        let file = GhosttyOverrideFile.temporary()
        let settings = GhosttyColorSettings(host: FakeSurfaceHost(), file: file)
        settings.setColor(GhosttyOverrideFile.ColorKey.background, to: ColorHex.color(from: "#303446"))
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.background) == "#303446")
    }

    @Test func theStoredColourIsReadableBackAsAColour() throws {
        let settings = GhosttyColorSettings(host: FakeSurfaceHost(), file: .temporary())
        settings.setColor(GhosttyOverrideFile.ColorKey.foreground, to: ColorHex.color(from: "#c6d0f5"))
        let colour = try #require(settings.color(for: GhosttyOverrideFile.ColorKey.foreground))
        #expect(ColorHex.string(from: colour) == "#c6d0f5")
    }

    /// Clearing a colour writes nil (removing the line) and still reloads, so the
    /// terminal drops back to the user's own theme immediately.
    @Test func clearingAColourRemovesItAndReloads() throws {
        let file = GhosttyOverrideFile.temporary()
        let host = FakeSurfaceHost()
        let settings = GhosttyColorSettings(host: host, file: file)
        settings.setColor(GhosttyOverrideFile.ColorKey.background, to: ColorHex.color(from: "#303446"))
        settings.setColor(GhosttyOverrideFile.ColorKey.background, to: nil)
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.background) == nil)
        #expect(settings.color(for: GhosttyOverrideFile.ColorKey.background) == nil)
        #expect(host.reloadCount == 2)
    }

    /// The colours a file already carries are read on construction, so opening
    /// Settings shows what is in effect rather than a blank set of wells.
    @Test func itReadsColoursTheFileAlreadyHas() throws {
        let file = GhosttyOverrideFile.temporary()
        try file.setColor(GhosttyOverrideFile.ColorKey.selectionBackground, to: "#626880")
        let settings = GhosttyColorSettings(host: FakeSurfaceHost(), file: file)
        let colour = try #require(settings.color(for: GhosttyOverrideFile.ColorKey.selectionBackground))
        #expect(ColorHex.string(from: colour) == "#626880")
    }

    /// A write that fails is reported and not followed by a reload, which would hand
    /// libghostty the file as it still is and report the unchanged colour as the new one.
    @Test func aFailedWriteIsReportedAndNothingIsReloaded() {
        let host = FakeSurfaceHost()
        let unwritable = GhosttyOverrideFile(url: URL(fileURLWithPath: "/dev/null/wietty/ghostty.cfg"))
        let settings = GhosttyColorSettings(host: host, file: unwritable)
        settings.setColor(GhosttyOverrideFile.ColorKey.background, to: ColorHex.color(from: "#303446"))
        #expect(settings.writeFailure != nil)
        #expect(host.reloadCount == 0)
    }

    /// A launch with no libghostty still writes the file: the colour applies on the
    /// next launch even though there is nothing to reload now.
    @Test func withNoHostItStillWritesTheFile() {
        let file = GhosttyOverrideFile.temporary()
        let settings = GhosttyColorSettings(host: nil, file: file)
        settings.setColor(GhosttyOverrideFile.ColorKey.background, to: ColorHex.color(from: "#303446"))
        #expect(file.color(for: GhosttyOverrideFile.ColorKey.background) == "#303446")
        #expect(settings.writeFailure == nil)
    }
}
