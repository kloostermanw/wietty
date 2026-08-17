import SwiftUI
import AppKit

/// Which background a terminal row in the sidebar draws.
///
/// Selection and hover are independent facts that are often both true at once, so
/// the precedence is decided here rather than inside the view: which terminal the
/// libghostty pane is showing is a property of the app, while hover is only where
/// the pointer happens to be. A row that gave its selection colour up whenever the
/// pointer crossed it would flicker between the two on the way to its own action
/// buttons, and the pointer is on the selected row for most of the time anyone is
/// looking at it. Hover stays visible on a selected row anyway, because the
/// trailing action buttons appear either way.
enum SidebarRowBackground: Equatable {
    /// Neither selected nor hovered: no background at all, so the card behind it
    /// shows through.
    case none
    /// The pointer is on the row and it is not the one on screen.
    case hovered
    /// The terminal this row stands for is the one the pane is showing.
    case selected

    static func resolve(isSelected: Bool, isHovered: Bool) -> SidebarRowBackground {
        if isSelected { return .selected }
        return isHovered ? .hovered : .none
    }

    /// The corner radius both fills are drawn with, so hovering a selected row
    /// cannot change the shape under the pointer.
    static let cornerRadius: Double = 5

    /// What to fill with, and nil for the row that draws nothing. The built-in
    /// behaviour, with no user override for the selected row's colour.
    var fill: AnyShapeStyle? { fill(activeRowBackground: nil) }

    /// The fill given the user's optional override for the selected row's background
    /// (`SidebarColors.activeTerminalRowBackground`). The override replaces the
    /// built-in `#292b34`/system selected colour; hover and none are untouched, since
    /// those are not colours the user sets.
    func fill(activeRowBackground: Color?) -> AnyShapeStyle? {
        switch self {
        case .none:
            return nil
        // Relative to whatever is behind it rather than a literal, which is what
        // makes the same row legible on both appearances. Over the sidebar in dark
        // mode this lands on #2d2d2d.
        case .hovered:
            return AnyShapeStyle(HierarchicalShapeStyle.secondary.opacity(0.12))
        case .selected:
            if let activeRowBackground {
                return AnyShapeStyle(activeRowBackground)
            }
            return AnyShapeStyle(Color(nsColor: Self.selectedFill))
        }
    }

    /// The selected row's fill, resolved against whichever appearance is drawing.
    static var selectedFill: NSColor {
        NSColor(name: nil) { selectedFill(for: $0) }
    }

    /// A literal colour in dark appearance, and the system's own in light.
    ///
    /// #292b34 is specified rather than derived. The stock row selections are both
    /// wrong here: the accent tinted `selectedContentBackgroundColor` is far
    /// stronger than a row saying "this is the one on screen" needs, and
    /// `unemphasizedSelectedContentBackgroundColor` is a grey close enough to the
    /// hover fill's #2d2d2d in dark mode to be unreadable next to it. #292b34 is
    /// set apart by hue rather than brightness, which is what lets a selected row
    /// read as selected with the pointer on it.
    ///
    /// Only dark appearance is specified, so light appearance keeps the system
    /// colour: an opaque near black row would be a blot on a white sidebar, and the
    /// unemphasized selection is already what a list row selected in an unfocused
    /// window looks like everywhere else on macOS.
    static func selectedFill(for appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua,
                                                .accessibilityHighContrastAqua,
                                                .accessibilityHighContrastDarkAqua])
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        return isDark ? darkSelected : .unemphasizedSelectedContentBackgroundColor
    }

    /// Computed rather than stored: `NSColor` is not `Sendable`, so a static `let`
    /// of one does not compile under strict concurrency.
    private static var darkSelected: NSColor {
        NSColor(srgbRed: 0x29 / 255.0, green: 0x2b / 255.0, blue: 0x34 / 255.0, alpha: 1)
    }
}
