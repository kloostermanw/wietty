import Foundation
import Observation
import WiettyCore

/// The settings that are this Mac's view of the data rather than part of it.
///
/// Four of them, decided by one rule: the server's own behaviour does not depend on
/// any of these with no frontend attached (issue #84). Nothing inside `ProjectStore`
/// reads them. They are how wide the sidebar is, what colour it is, which group it
/// is filtering to, and which sound a banner plays, and a terminal runs the same
/// either way.
///
/// In the app target rather than the core, because two of the four are what would
/// otherwise drag SwiftUI and AppKit across the boundary: `SidebarColors` holds
/// SwiftUI `Color`s and `BellSound` reaches `NSSound`.
///
/// It shares `ProjectStore`'s `SettingsWriter`, so both still write one file in one
/// order. See `SettingsKeys.fileOrder` for why that order is declared rather than
/// left to whichever source was registered first.
@MainActor
@Observable
final class UIPreferences: SettingsPairSource {
    private let writer: SettingsWriter
    /// The ids of the groups that currently exist, for resolving the selection. A
    /// closure rather than a stored list because the groups belong to the store and
    /// change under this.
    private let knownGroupIds: @MainActor () -> Set<UUID>

    /// The sound every notification a terminal posts plays. Persisted, and applied
    /// to the next notification rather than needing a restart.
    var bellSound: BellSound {
        didSet {
            guard bellSound != oldValue else { return }
            writer.write()
        }
    }

    /// How wide the sidebar is. Persisted, so the divider stays where the user put it
    /// across relaunches.
    ///
    /// Clamped to the sidebar's own floor on the way in and out, because nothing
    /// guarantees a stored value came from this build or from a window this size. The
    /// upper bound is not applied here: it depends on the window's current width, so
    /// `ContentView` applies `SidebarWidth.clamped(desired:totalWidth:)` at layout
    /// time.
    ///
    /// Written on drag end rather than during the drag. The live width lives in
    /// `ContentView`'s own state while the divider is moving, so one drag is one
    /// write here instead of one per frame.
    var sidebarWidth: Double {
        didSet {
            let floored = max(sidebarWidth, SidebarWidth.minimum)
            if floored != sidebarWidth { sidebarWidth = floored; return }
            guard sidebarWidth != oldValue else { return }
            writer.write()
        }
    }

    /// The sidebar's own colours, each optional (nil leaves the default). Persisted as
    /// `color-*` scalar keys; the terminal's colours are separate and live in
    /// `ghostty.cfg` (`GhosttyColorSettings`) because only libghostty can apply them.
    var sidebarColors: SidebarColors {
        didSet {
            guard sidebarColors != oldValue else { return }
            writer.write()
        }
    }

    /// What the file holds, which is not always what `selectedGroupId` answers.
    private var storedSelectedGroupId: UUID?

    /// The group whose workspaces the sidebar is showing, or nil for "All".
    ///
    /// Resolved against the groups that exist, every read. The store used to clear
    /// this itself when the active group was removed, which it cannot do from the
    /// other side of the module boundary, and resolving on read is the same answer
    /// from one rule instead of two: it already had to drop an id no group answers to
    /// when loading a hand-edited file or one an older build left behind.
    var selectedGroupId: UUID? {
        get {
            guard let stored = storedSelectedGroupId,
                  knownGroupIds().contains(stored) else { return nil }
            return stored
        }
        set {
            guard newValue != storedSelectedGroupId else { return }
            storedSelectedGroupId = newValue
            writer.write()
        }
    }

    init(launch: SettingsLaunch,
         writer: SettingsWriter,
         knownGroupIds: @escaping @MainActor () -> Set<UUID>) {
        self.writer = writer
        self.knownGroupIds = knownGroupIds
        let cfg = launch.values
        self.bellSound = BellSound(stored: cfg[SettingsKeys.bellSound] ?? "")
        self.sidebarWidth = Self.width(cfg[SettingsKeys.sidebarWidth])
        self.sidebarColors = SidebarColors(from: cfg)
        self.storedSelectedGroupId = cfg[SettingsKeys.selectedGroup].flatMap { UUID(uuidString: $0) }
        writer.add(self)
        // The store seeded the file before this existed, so that seed carries none of
        // these lines. One write puts them in, which matters because the migration has
        // already removed the `UserDefaults` keys they came from.
        if launch.migrating { writer.write() }
    }

    private static func width(_ value: String?) -> Double {
        guard let value, let width = Double(value), width != 0 else { return SidebarWidth.default }
        return max(width, SidebarWidth.minimum)
    }

    /// This source's lines. The resolved selection rather than the stored one, so a
    /// removed group's id leaves the file on the next write exactly as it did when the
    /// store cleared it by hand.
    var settingsPairs: [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = [
            (SettingsKeys.bellSound, bellSound.stored),
            (SettingsKeys.sidebarWidth, String(sidebarWidth)),
        ]
        pairs.append(contentsOf: sidebarColors.pairs)
        if let selectedGroupId {
            pairs.append((SettingsKeys.selectedGroup, selectedGroupId.uuidString))
        }
        return pairs
    }
}
