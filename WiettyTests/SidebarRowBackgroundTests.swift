import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// The background a terminal row draws, which is the whole of what
/// `TerminalRowView` decides about selection. The view itself is a rounded
/// rectangle filled with whatever this answers, so asserting the answer is
/// asserting the row.
@Suite struct SidebarRowBackgroundTests {
    @Test func anIdleRowDrawsNothing() {
        #expect(SidebarRowBackground.resolve(isSelected: false, isHovered: false) == .none)
        #expect(SidebarRowBackground.resolve(isSelected: false, isHovered: false).fill == nil)
    }

    @Test func hoverAloneIsTheHoverFill() {
        #expect(SidebarRowBackground.resolve(isSelected: false, isHovered: true) == .hovered)
        #expect(SidebarRowBackground.resolve(isSelected: false, isHovered: true).fill != nil)
    }

    @Test func selectionAloneIsTheSelectedFill() {
        #expect(SidebarRowBackground.resolve(isSelected: true, isHovered: false) == .selected)
    }

    /// The precedence, and the reason this is a function rather than two nested
    /// `if`s in the view: the pointer sits on the selected row for most of the time
    /// anyone is looking at it, so losing the selection colour to hover would mean
    /// the row on screen is the one least often marked as such.
    @Test func selectionSurvivesThePointerCrossingIt() {
        #expect(SidebarRowBackground.resolve(isSelected: true, isHovered: true) == .selected)
    }

    /// The colour was specified, so it is pinned. Anything that changes it changes
    /// what the user asked for.
    @Test func theSelectedRowIsTheSpecifiedColourInDarkAppearance() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let fill = try #require(SidebarRowBackground.selectedFill(for: dark)
            .usingColorSpace(.sRGB))
        // #292b34.
        #expect(abs(fill.redComponent - 0x29 / 255.0) < 0.002)
        #expect(abs(fill.greenComponent - 0x2b / 255.0) < 0.002)
        #expect(abs(fill.blueComponent - 0x34 / 255.0) < 0.002)
        #expect(fill.alphaComponent == 1)
    }

    /// The literal is dark appearance only. An opaque near black row on a white
    /// sidebar would be a blot rather than a selection, so light appearance keeps
    /// the system's own unemphasized row selection.
    @Test func lightAppearanceDoesNotGetTheDarkColour() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(SidebarRowBackground.selectedFill(for: light)
            != SidebarRowBackground.selectedFill(for: dark))
        #expect(SidebarRowBackground.selectedFill(for: light)
            == NSColor.unemphasizedSelectedContentBackgroundColor)
    }

    /// High contrast is an appearance of its own, and matching it by name alone
    /// would have sent a dark high contrast window down the light branch.
    @Test func highContrastAppearancesFollowTheirOwnSide() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        if let hcDark = NSAppearance(named: .accessibilityHighContrastDarkAqua) {
            #expect(SidebarRowBackground.selectedFill(for: hcDark)
                == SidebarRowBackground.selectedFill(for: dark))
        }
        if let hcLight = NSAppearance(named: .accessibilityHighContrastAqua) {
            #expect(SidebarRowBackground.selectedFill(for: hcLight)
                == SidebarRowBackground.selectedFill(for: light))
        }
    }

    /// Both fills use one radius, so hovering a selected row cannot change the
    /// shape under the pointer.
    @Test func bothFillsShareOneCornerRadius() {
        #expect(SidebarRowBackground.cornerRadius == 5)
    }
}

/// The row as drawn, rather than the decision behind it.
///
/// Everything above asserts what `TerminalRowView` is told to fill with, and none
/// of it would catch the fill never reaching the screen: a background modifier
/// attached to the wrong subview, a `ViewBuilder` branch that never runs, an
/// opacity applied on top. So the row is rendered offscreen in dark appearance and
/// the pixel is read back.
@MainActor
@Suite struct TerminalRowBackgroundRenderTests {
    /// Renders a row and returns the colour at the trailing edge, vertically
    /// centred. Nothing is drawn there: the label is leading, and the action
    /// buttons only appear on hover, which cannot happen without a pointer.
    private func backgroundPixel(isSelected: Bool) throws -> NSColor {
        let row = TerminalRowView(label: "Terminal 1",
                                  kind: .terminal,
                                  isSelected: isSelected,
                                  onPlay: {}, onStop: {}, onRestart: {})
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

    @Test func aSelectedRowRendersTheSpecifiedColour() throws {
        let pixel = try backgroundPixel(isSelected: true)
        // #292b34, the colour asked for, on the screen rather than in a constant.
        #expect(abs(pixel.redComponent - 0x29 / 255.0) < 0.01)
        #expect(abs(pixel.greenComponent - 0x2b / 255.0) < 0.01)
        #expect(abs(pixel.blueComponent - 0x34 / 255.0) < 0.01)
    }

    /// The other half of the same check: an unselected row must draw no background
    /// of its own, or every row would look selected and the test above would pass on
    /// a row that fills unconditionally.
    @Test func anUnselectedRowRendersNoBackground() throws {
        let pixel = try backgroundPixel(isSelected: false)
        #expect(pixel.alphaComponent == 0)
    }
}
