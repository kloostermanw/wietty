import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// Whether a workspace card draws the active highlight, and in which colour. The
/// card is "active" when it owns the terminal the pane is showing; the colour only
/// applies then, and only when the user set one, so an untouched install still draws
/// no card background.
@Suite struct WorkspaceHighlightTests {
    @Test func anInactiveCardDrawsNoBackground() {
        #expect(WorkspaceHighlight.resolve(isActive: false)
            .background(active: ColorHex.color(from: "#303446")) == nil)
    }

    @Test func anActiveCardWithNoOverrideDrawsNoBackground() {
        #expect(WorkspaceHighlight.resolve(isActive: true).background(active: nil) == nil)
    }

    @Test func anActiveCardDrawsTheOverride() throws {
        let colour = try #require(ColorHex.color(from: "#303446"))
        #expect(WorkspaceHighlight.resolve(isActive: true).background(active: colour) == colour)
    }
}

/// The active terminal row's background override reaching the screen. The pure
/// `SidebarRowBackground` fill cannot be asserted for colour (an `AnyShapeStyle` is
/// not `Equatable`), so the row is rendered with an override in the environment and
/// the pixel is read back, the same way `TerminalRowBackgroundRenderTests` reads the
/// built-in selected colour.
@MainActor
@Suite struct ActiveRowColorRenderTests {
    private func backgroundPixel(override: Color) throws -> NSColor {
        let row = TerminalRowView(label: "Terminal 1", kind: .terminal, isSelected: true,
                                  onPlay: {}, onStop: {}, onRestart: {}, onClose: {})
            .environment(\.sidebarColors, SidebarColors(activeTerminalRowBackground: override))
        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let pixel = try #require(rep.colorAt(x: Int(host.bounds.width) - 3,
                                             y: Int(host.bounds.height / 2)))
        return try #require(pixel.usingColorSpace(.sRGB))
    }

    @Test func aSelectedRowUsesTheOverrideColour() throws {
        let override = try #require(ColorHex.color(from: "#804020"))
        let pixel = try backgroundPixel(override: override)
        #expect(abs(pixel.redComponent - 0x80 / 255.0) < 0.02)
        #expect(abs(pixel.greenComponent - 0x40 / 255.0) < 0.02)
        #expect(abs(pixel.blueComponent - 0x20 / 255.0) < 0.02)
    }
}
