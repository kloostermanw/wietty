import AppKit
import SwiftUI

/// A colour as a `#RRGGBB` string and back.
///
/// Both files Wietty writes a colour into (`~/.config/wietty/config` for its own UI
/// colours, `~/.config/wietty/ghostty.cfg` for the terminal's) spell one this way,
/// and it is Ghostty's own syntax, so a value written here is a value Ghostty reads.
/// One place for the conversion so the reader and the writer cannot disagree about
/// what `#303446` means.
///
/// sRGB throughout: a colour is decomposed and recomposed in that space so the
/// bytes written match the bytes read, rather than depending on whatever space a
/// given `NSColor`/`Color` happened to carry.
enum ColorHex {
    /// Parses `#RRGGBB` (the `#` optional, case insensitive) into an sRGB colour, or
    /// nil for anything that is not exactly six hex digits.
    static func nsColor(from hex: String) -> NSColor? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6,
              let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255.0,
                       green: Double((value >> 8) & 0xFF) / 255.0,
                       blue: Double(value & 0xFF) / 255.0,
                       alpha: 1)
    }

    /// `#rrggbb`, lowercase, from a colour's sRGB components. Nil when the colour has
    /// no sRGB representation (a pattern colour has none), which no colour this type
    /// produces ever is.
    static func string(from nsColor: NSColor) -> String? {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// The SwiftUI `Color` the settings' `ColorPicker`s bind to.
    static func color(from hex: String) -> Color? {
        nsColor(from: hex).map(Color.init(nsColor:))
    }

    static func string(from color: Color) -> String? {
        string(from: NSColor(color))
    }
}
