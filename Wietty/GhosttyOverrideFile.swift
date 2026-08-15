import Foundation

/// Wietty's own Ghostty configuration, at `~/.config/wietty/ghostty.cfg`.
///
/// libghostty is configured by loading files in order, and the last file to set a
/// key wins. That is measured rather than assumed: two files setting
/// `desktop-notifications` resolve to whichever was loaded second, in both
/// directions. `GhosttySurfaceHost` therefore loads the user's own Ghostty config
/// first, so the font and theme they chose still apply, and this file after it, so
/// a setting Wietty offers in its own Settings window is the one that takes effect.
///
/// It is a file rather than a `UserDefaults` key because libghostty has no setter.
/// `ghostty_config_get` reads a value and nothing writes one, so handing libghostty
/// another file is the only way to change a setting at all.
///
/// The file is Wietty's, but it lives in the user's `~/.config` and they may well
/// edit it. So it is rewritten line by line rather than regenerated: a line this
/// type does not manage survives a toggle untouched, comments included.
struct GhosttyOverrideFile {
    let url: URL

    /// `~/.config/wietty/ghostty.cfg`. Deliberately beside `~/.config/ghostty/`
    /// rather than inside it: that directory is Ghostty's, and a file Wietty writes
    /// there would be read by Ghostty.app too.
    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/wietty/ghostty.cfg")
    }

    init(url: URL = GhosttyOverrideFile.defaultURL) {
        self.url = url
    }

    /// What this file says about desktop notifications, or nil when it says nothing
    /// and libghostty is left to resolve the value from the user's own config.
    ///
    /// Nil and false are different answers and the caller has to tell them apart:
    /// nil defers, false overrides.
    var desktopNotifications: Bool? {
        switch value(for: Self.desktopNotificationsKey) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Writes the setting, or removes it when `on` is nil so libghostty goes back to
    /// resolving it from the user's own config.
    ///
    /// Creates the file and its directory when they are absent, which is the usual
    /// case: nothing else in Wietty writes to `~/.config`.
    func setDesktopNotifications(_ on: Bool?) throws {
        try set(Self.desktopNotificationsKey, to: on.map { $0 ? "true" : "false" })
    }

    private static let desktopNotificationsKey = "desktop-notifications"

    // MARK: The format

    /// Only as much of Ghostty's config syntax as this type writes: `key = value`
    /// one per line, `#` starting a comment. That is enough to find and replace a
    /// line it put there itself, and it deliberately does not try to be a config
    /// parser. What the setting actually resolves to is libghostty's answer, read
    /// back through `ghostty_config_get`, not this file's.
    private func value(for key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Last wins, matching how libghostty resolves a key set more than once.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { Self.pair(in: String($0)) }
            .last { $0.key == key }?
            .value
    }

    private func set(_ key: String, to value: String?) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty
            ? [] : existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A trailing newline splits into a final empty element. Dropping it here and
        // adding one back on write keeps a toggle from growing a blank line each time.
        if lines.last == "" { lines.removeLast() }

        lines.removeAll { Self.pair(in: $0)?.key == key }
        if let value { lines.append("\(key) = \(value)") }

        // An emptied file is left in place rather than deleted. libghostty reads a
        // missing file as no diagnostics and no values, so both mean the same thing
        // to it, and a file the user can still find explains itself better than one
        // that vanished.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let text = lines.isEmpty ? Self.header : (Self.header + lines.joined(separator: "\n") + "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Says whose file this is, because it appears in a directory the user owns and
    /// nothing else would explain where it came from.
    private static let header = """
    # Written by Wietty. Loaded after ~/.config/ghostty/config, so what is set here
    # wins for Wietty's terminals and does not affect Ghostty.app.

    """

    /// The `key = value` in one line, or nil for a comment, a blank line, or
    /// anything this type does not recognise. Anything returning nil is preserved
    /// exactly as it was.
    private static func pair(in line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}
