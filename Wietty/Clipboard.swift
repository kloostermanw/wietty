import AppKit

/// Writes a string to the system pasteboard. A single place for the
/// clear-then-set pair so every "Copy …" action copies the same way the terminal's
/// own copy path does in `GhosttySurfaceHost`.
enum Clipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
