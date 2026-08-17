import Foundation
import Observation
import SwiftUI

/// The Settings window's control over the terminal's colours, written to
/// `GhosttyOverrideFile` (`~/.config/wietty/ghostty.cfg`) and applied by asking the
/// host to reload, so a colour changed here reaches terminals that are already open.
///
/// It reads the override file's own values rather than libghostty's resolved ones.
/// A colour Wietty is forcing is exactly what the file says, and unlike the boolean
/// `desktop-notifications`, reading a resolved colour back through `ghostty_config_get`
/// is a good deal more work than it is worth for what the wells need to show. The
/// consequence, spelled out in the caption, is that these wells show what Wietty
/// overrides, not what the user's own theme resolves to when Wietty overrides nothing.
@MainActor
@Observable
final class GhosttyColorSettings {
    /// Strong, and nil only for the launch with no libghostty at all, for the same
    /// reasons as `DesktopNotificationSetting.host`.
    private let host: (any TerminalSurfaceHosting)?
    private let file: GhosttyOverrideFile

    /// Why the last write failed, for the one thing the user can act on: `~/.config`
    /// is not otherwise Wietty's to write, so a permission problem there is plausible.
    private(set) var writeFailure: String?

    /// The colours the file currently sets, by Ghostty key. A key the file does not
    /// carry is absent here, which the wells draw as "no override".
    ///
    /// Stored rather than computed for the same reason `DesktopNotificationSetting`'s
    /// value is: `@Observable` tracks reads of stored properties, and the file is not
    /// one, so a well reading through it would register no dependency and not redraw.
    private(set) var colors: [String: Color] = [:]

    init(host: (any TerminalSurfaceHosting)?, file: GhosttyOverrideFile = GhosttyOverrideFile()) {
        self.host = host
        self.file = file
        refresh()
    }

    var fileURL: URL { file.url }

    /// The colour set for a key, or nil when the file sets none.
    func color(for key: String) -> Color? { colors[key] }

    /// Re-reads every colour from the file. Called on the way into the tab as well as
    /// after a write, because the file is an ordinary one the user can edit while the
    /// window is open.
    func refresh() {
        var loaded: [String: Color] = [:]
        for key in GhosttyOverrideFile.ColorKey.all {
            if let hex = file.color(for: key), let colour = ColorHex.color(from: hex) {
                loaded[key] = colour
            }
        }
        colors = loaded
    }

    /// Writes a colour, or clears it when `color` is nil, then reloads so the change
    /// is live. A failed write is reported and not followed by a reload, which would
    /// otherwise report the unchanged file as the new value.
    func setColor(_ key: String, to color: Color?) {
        do {
            try file.setColor(key, to: color.flatMap(ColorHex.string(from:)))
            writeFailure = nil
            host?.reloadConfig()
            refresh()
        } catch {
            writeFailure = error.localizedDescription
        }
    }
}
