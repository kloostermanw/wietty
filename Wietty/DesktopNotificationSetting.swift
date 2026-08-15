import Foundation
import Observation

/// The Settings window's control over `desktop-notifications`, which is the gate
/// every `OSC 9` and `OSC 777` notification passes through.
///
/// This exists because the gate was invisible. libghostty reads the user's own
/// Ghostty config (`GhosttySurfaceHost`), that config can turn desktop
/// notifications off, and when it does a program asking for one is answered by
/// nothing at all: no banner, no 🔔, no error. Nothing in Wietty said so, and the
/// Settings window is where somebody looks when notifications are not arriving.
///
/// It writes `GhosttyOverrideFile` and then asks the host to reload, so the change
/// reaches terminals that are already open rather than only the next launch.
@MainActor
@Observable
final class DesktopNotificationSetting {
    /// Strong, and it has to be. Nothing on the host refers back here, so there is no
    /// cycle to avoid, and a weak reference buys a failure mode worth avoiding: a
    /// host that had gone would leave this reporting libghostty's defaults and
    /// writing a file nothing ever reloads, which is a toggle that looks like it
    /// works and does nothing. Nil is reserved for the launch that has no libghostty
    /// at all.
    private let host: (any TerminalSurfaceHosting)?
    private let file: GhosttyOverrideFile

    /// Why the last write failed, for the one thing that can go wrong that the user
    /// can act on. `~/.config` is not somewhere Wietty otherwise writes, so a
    /// permissions problem there is plausible and would otherwise show as a toggle
    /// that springs back with no explanation.
    private(set) var writeFailure: String?

    init(host: (any TerminalSurfaceHosting)?, file: GhosttyOverrideFile = GhosttyOverrideFile()) {
        self.host = host
        self.file = file
        refresh()
    }

    /// What libghostty resolved, which is what actually decides whether a
    /// notification arrives.
    ///
    /// Stored rather than computed, and that is not a caching decision. `@Observable`
    /// tracks reads of this object's own stored properties, and neither the host nor
    /// the file is one, so a computed property reading through them would register no
    /// dependency: the toggle would write, the value would change, and SwiftUI would
    /// redraw the switch in its old position.
    private(set) var isEnabled = true

    /// True when Wietty's file is the reason `isEnabled` reads as it does, against
    /// what the user's own Ghostty config asked for. The toggle says so when it is,
    /// because a Wietty switch quietly contradicting their config would otherwise
    /// look like Wietty had ignored it.
    private(set) var overridesUserConfig = false

    /// What the user's own Ghostty config asks for, shown only when it differs.
    private(set) var userConfigValue = true

    /// True when Wietty's file holds the key at all. Offering "use my Ghostty config"
    /// for a file with no override in it would be a button with nothing to do.
    private(set) var hasOverride = false

    /// Re-reads libghostty and the file. Called on the way into the Settings tab as
    /// well as after a write, because both config files are ordinary files the user
    /// can edit while the window is open, and the tab is drawn from what this holds.
    func refresh() {
        let resolved = host?.desktopNotifications ?? (effective: true, userConfig: true)
        isEnabled = resolved.effective
        userConfigValue = resolved.userConfig
        overridesUserConfig = resolved.effective != resolved.userConfig
        hasOverride = file.desktopNotifications != nil
    }

    var fileURL: URL { file.url }

    func setEnabled(_ on: Bool) {
        write { try file.setDesktopNotifications(on) }
    }

    /// Drops Wietty's line and lets the user's own config decide again.
    func clearOverride() {
        write { try file.setDesktopNotifications(nil) }
    }

    private func write(_ change: () throws -> Void) {
        do {
            try change()
            writeFailure = nil
            // Only after a successful write: reloading first would hand libghostty
            // the file as it was and report the old value as the new one.
            host?.reloadConfig()
            refresh()
        } catch {
            writeFailure = error.localizedDescription
        }
    }
}
