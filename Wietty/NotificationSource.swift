import Foundation

/// Which sequence a program's banners come from, chosen on the Notifications tab.
///
/// Two, because one agent can send both and would otherwise be announced twice:
/// Claude Code sends `OSC 777` when it waits on you (it treats this app as Ghostty,
/// see `docs/notifications.md`) and, from 2.1.295, also reports `OSC 7501` program
/// status. Whichever is chosen, the row always shows the program status.
enum NotificationSource: String, CaseIterable, Identifiable, Sendable {
    /// `OSC 9` and `OSC 777`: what this app always did, and the default.
    case desktopNotifications = "osc-9-777"
    /// `OSC 7501`: a banner when a program starts waiting on you, finishes, or
    /// fails, and the `OSC 9` and `OSC 777` of a terminal reporting it are dropped.
    /// A terminal that never reports it keeps its desktop notifications.
    case programStatus = "osc-7501"

    var id: String { rawValue }

    /// A value this build cannot read (written by a later one, or edited by hand)
    /// is the default, which is the behaviour from before there was a choice.
    init(stored: String) {
        self = Self(rawValue: stored) ?? .desktopNotifications
    }

    var stored: String { rawValue }

    var title: String {
        switch self {
        case .desktopNotifications: return "OSC 9 and OSC 777"
        case .programStatus: return "OSC 7501 (program status)"
        }
    }
}
