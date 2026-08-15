import AppKit
import UserNotifications

/// Which sound a notification from a terminal plays.
///
/// A type rather than a bare string in `UserDefaults` for the usual reason: what
/// the picker offers, what a stored value means, and what an unreadable one falls
/// back to are decisions, and decisions belong somewhere a test can reach.
enum BellSound: Equatable, Hashable, Identifiable {
    /// A banner and nothing audible. The 🔔 in the sidebar still appears.
    case silent
    /// Whatever the user picked as the system alert sound, which is what this app
    /// played before there was a setting. Still the default, so an upgrade changes
    /// nothing for someone who never opens this tab.
    case systemDefault
    /// One of the sounds in `/System/Library/Sounds`, by its name without the
    /// extension ("Ping", "Submarine").
    case named(String)

    var id: String { stored }

    /// What the picker shows.
    var title: String {
        switch self {
        case .silent: return "None"
        case .systemDefault: return "Default"
        case .named(let name): return name
        }
    }

    // MARK: - Persisted form

    /// The string written to `UserDefaults`.
    ///
    /// Spelled out rather than derived, because "" and "default" have to stay
    /// distinguishable from a sound that happens to be called either: a preference
    /// that decoded to silence after a macOS release added a sound named `default`
    /// would be a bug nobody could explain.
    var stored: String {
        switch self {
        case .silent: return "none"
        case .systemDefault: return "default"
        case .named(let name): return "named:\(name)"
        }
    }

    /// The reverse. Anything unrecognised, including the empty string a store with
    /// no preference yet reads, is the default sound rather than silence: a value
    /// this build cannot read is not a reason to stop making a noise the user asked
    /// for.
    init(stored: String) {
        switch stored {
        case "none": self = .silent
        case let value where value.hasPrefix("named:"):
            let name = String(value.dropFirst("named:".count))
            self = name.isEmpty ? .systemDefault : .named(name)
        default: self = .systemDefault
        }
    }

    // MARK: - What the picker offers

    /// Where macOS keeps the sounds every app can play. `~/Library/Sounds` and
    /// `/Library/Sounds` also exist and are deliberately not read: they are empty on
    /// a stock Mac, and a list that varies per machine is one the documentation
    /// cannot describe.
    static let systemSoundsDirectory = URL(fileURLWithPath: "/System/Library/Sounds")

    /// What the picker offers, read once per launch. Sounds are not installed while
    /// the app runs, and a view's body is rebuilt on every keystroke elsewhere in
    /// the form, which is not a reason to read a directory.
    static let offered: [BellSound] = available()

    /// Silence, the system default, and then the installed sounds by name.
    ///
    /// - Parameter directory: only the tests pass anything else.
    static func available(in directory: URL = systemSoundsDirectory) -> [BellSound] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let sounds = names
            .filter { $0.hasSuffix(".aiff") }
            .map { BellSound.named(String($0.dropLast(".aiff".count))) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return [.silent, .systemDefault] + sounds
    }

    // MARK: - Playing it

    /// The sound to hang on a notification.
    ///
    /// `UNNotificationSound(named:)` takes the file name including its extension, and
    /// does not resolve it the way `play()` below does: it looks in the app bundle and
    /// the container's `Library/Sounds`, while `NSSound(named:)` searches
    /// `/System/Library/Sounds` as well. A name it cannot resolve is not an error
    /// either, because the initialiser cannot fail and `add` does not validate the
    /// sound: the banner is posted with the default sound and nothing reports it.
    ///
    /// So the two buttons in the Notifications tab check different things on purpose,
    /// and only one of them checks this: "Send test notification" posts a real banner
    /// through this path, and the "Test" beside the picker is a preview of the file.
    var notificationSound: UNNotificationSound? {
        switch self {
        case .silent: return nil
        case .systemDefault: return .default
        case .named(let name): return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }

    /// Plays it now, for the Test button beside the picker.
    ///
    /// Returns false when there was nothing to play or the file could not be
    /// loaded, and the caller has to draw that: a button that fails silently is
    /// indistinguishable from a sound that is not there. `.systemDefault` goes
    /// through `NSSound.beep`, because the system alert sound is a preference of the
    /// user's rather than a file this app can name.
    ///
    /// A preview of the file, not a check of the banner. See `notificationSound` for
    /// why the two resolve a name differently.
    @discardableResult
    func play() -> Bool {
        switch self {
        case .silent:
            return false
        case .systemDefault:
            NSSound.beep()
            return true
        case .named(let name):
            guard let sound = NSSound(named: NSSound.Name(name)) else { return false }
            return sound.play()
        }
    }
}
