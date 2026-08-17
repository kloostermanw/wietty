import SwiftUI

/// The colours the sidebar can be given from Settings.
///
/// Each is optional and nil means "leave the default": an untouched install sets
/// none of them, so the sidebar keeps the system colours and the terminal row keeps
/// its built-in `#292b34`. Nil is also what deleting the line in
/// `~/.config/wietty/config` returns to, so setting a colour to nil removes its line
/// rather than writing an empty one.
///
/// A value type held on `ProjectStore` like `CheckIntervals`: persisted as scalar
/// keys, so the reader and writer round-trip through the same `SettingsKeys` names.
struct SidebarColors: Equatable {
    var background: Color?
    var foreground: Color?
    var activeWorkspaceBackground: Color?
    var activeWorkspaceForeground: Color?
    var activeTerminalRowBackground: Color?
    var activeTerminalRowForeground: Color?

    init(background: Color? = nil,
         foreground: Color? = nil,
         activeWorkspaceBackground: Color? = nil,
         activeWorkspaceForeground: Color? = nil,
         activeTerminalRowBackground: Color? = nil,
         activeTerminalRowForeground: Color? = nil) {
        self.background = background
        self.foreground = foreground
        self.activeWorkspaceBackground = activeWorkspaceBackground
        self.activeWorkspaceForeground = activeWorkspaceForeground
        self.activeTerminalRowBackground = activeTerminalRowBackground
        self.activeTerminalRowForeground = activeTerminalRowForeground
    }

    /// Reads whichever of the six keys the file carries; a key it does not carry, or
    /// one whose value is not a `#RRGGBB` colour, stays nil.
    init(from cfg: [String: String]) {
        background = cfg[SettingsKeys.colorBackground].flatMap(ColorHex.color(from:))
        foreground = cfg[SettingsKeys.colorForeground].flatMap(ColorHex.color(from:))
        activeWorkspaceBackground = cfg[SettingsKeys.colorActiveWorkspaceBackground].flatMap(ColorHex.color(from:))
        activeWorkspaceForeground = cfg[SettingsKeys.colorActiveWorkspaceForeground].flatMap(ColorHex.color(from:))
        activeTerminalRowBackground = cfg[SettingsKeys.colorActiveTerminalRowBackground].flatMap(ColorHex.color(from:))
        activeTerminalRowForeground = cfg[SettingsKeys.colorActiveTerminalRowForeground].flatMap(ColorHex.color(from:))
    }

    /// One `(key, hex)` pair per colour that is set. A nil colour is omitted, so the
    /// writer drops its line (the keys are all managed scalars), which is what returns
    /// that element to its default.
    var pairs: [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        func add(_ key: String, _ colour: Color?) {
            if let colour, let hex = ColorHex.string(from: colour) { out.append((key, hex)) }
        }
        add(SettingsKeys.colorBackground, background)
        add(SettingsKeys.colorForeground, foreground)
        add(SettingsKeys.colorActiveWorkspaceBackground, activeWorkspaceBackground)
        add(SettingsKeys.colorActiveWorkspaceForeground, activeWorkspaceForeground)
        add(SettingsKeys.colorActiveTerminalRowBackground, activeTerminalRowBackground)
        add(SettingsKeys.colorActiveTerminalRowForeground, activeTerminalRowForeground)
        return out
    }
}

/// Whether a workspace card draws the active highlight, and the reason it is a type
/// of its own rather than an `if` in the card: "active" (the card owns the terminal
/// the pane is showing) gates a colour that only applies then, and only when the user
/// set one, so both conditions are asserted in CI rather than only visible by
/// selecting a row. It mirrors `SidebarRowBackground`, which does the same for a row.
enum WorkspaceHighlight {
    case none
    case active

    static func resolve(isActive: Bool) -> WorkspaceHighlight {
        isActive ? .active : .none
    }

    /// The card's background, which is the override only when the card is active and
    /// a colour was set. An untouched install sets none, so a card keeps drawing no
    /// background of its own.
    func background(active override: Color?) -> Color? {
        self == .active ? override : nil
    }
}

private struct SidebarColorsKey: EnvironmentKey {
    static let defaultValue = SidebarColors()
}

extension EnvironmentValues {
    /// The sidebar's colours, set once on the sidebar in `ContentView` and read by the
    /// rows and cards under it. Carried through the environment rather than as an
    /// initializer argument so a colour reaches every level of the sidebar without
    /// threading it through each view (and each view's tests) in between.
    var sidebarColors: SidebarColors {
        get { self[SidebarColorsKey.self] }
        set { self[SidebarColorsKey.self] = newValue }
    }
}
