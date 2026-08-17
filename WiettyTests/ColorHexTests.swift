import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// The one place a colour becomes a `#RRGGBB` string and back, so a colour written
/// to a config file and read from one cannot drift. Both config files Wietty writes
/// (`~/.config/wietty/config` and `~/.config/wietty/ghostty.cfg`) use this spelling,
/// and Ghostty's own syntax is the same, so a value round-tripped here is a value
/// Ghostty accepts.
@Suite struct ColorHexTests {
    @Test func parsesSixDigitHexIntoSRGBComponents() throws {
        let colour = try #require(ColorHex.nsColor(from: "#303446")).usingColorSpace(.sRGB)
        let resolved = try #require(colour)
        #expect(abs(resolved.redComponent - 0x30 / 255.0) < 0.002)
        #expect(abs(resolved.greenComponent - 0x34 / 255.0) < 0.002)
        #expect(abs(resolved.blueComponent - 0x46 / 255.0) < 0.002)
        #expect(resolved.alphaComponent == 1)
    }

    @Test func acceptsAHexWithNoLeadingHash() {
        #expect(ColorHex.nsColor(from: "303446") != nil)
    }

    @Test func isCaseInsensitive() throws {
        let lowerColour = try #require(ColorHex.nsColor(from: "#c6d0f5"))
        let upperColour = try #require(ColorHex.nsColor(from: "#C6D0F5"))
        #expect(ColorHex.string(from: lowerColour) == ColorHex.string(from: upperColour))
    }

    @Test func rejectsAnythingThatIsNotSixHexDigits() {
        #expect(ColorHex.nsColor(from: "") == nil)
        #expect(ColorHex.nsColor(from: "#12") == nil)
        #expect(ColorHex.nsColor(from: "#1234567") == nil)
        #expect(ColorHex.nsColor(from: "#gggggg") == nil)
        #expect(ColorHex.nsColor(from: "not a colour") == nil)
    }

    /// A colour written and read back is the same colour, which is the whole point:
    /// this is what a persisted colour survives a relaunch as.
    @Test func roundTripsAStringBackToItself() throws {
        let colour = try #require(ColorHex.nsColor(from: "#303446"))
        #expect(ColorHex.string(from: colour) == "#303446")
    }

    /// Output is lowercase with a leading `#`, matching the spelling Ghostty's own
    /// examples use, so a file Wietty writes reads the way a hand-edited one would.
    @Test func writesLowercaseWithALeadingHash() throws {
        let colour = try #require(ColorHex.nsColor(from: "#ABCDEF"))
        #expect(ColorHex.string(from: colour) == "#abcdef")
    }

    /// The SwiftUI `Color` convenience the settings bindings use round-trips too,
    /// since a `ColorPicker` hands back a `Color`, not an `NSColor`.
    @Test func roundTripsThroughSwiftUIColor() throws {
        let colour = try #require(ColorHex.color(from: "#626880"))
        #expect(ColorHex.string(from: colour) == "#626880")
    }
}
