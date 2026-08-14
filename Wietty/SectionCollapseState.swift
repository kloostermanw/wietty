import Foundation
import Observation

/// Tracks which sidebar sections (Local + each remote connection) are
/// collapsed. Backed by an `@Observable` stored property so toggling a
/// section triggers SwiftUI view invalidation; changes are also persisted
/// to `UserDefaults` so collapse state survives relaunch.
@MainActor
@Observable
final class SectionCollapseState {
    private var map: [String: Bool]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "wietty.sidebar.collapsed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.map = defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    /// Whether `k` is collapsed, answering `fallback` for a key nobody has
    /// toggled yet.
    ///
    /// Section headers want the stored default (a section starts open), and a
    /// remote workspace card wants the opposite (a connection serving a dozen
    /// workspaces must not fill the sidebar the moment it connects), so the
    /// starting side is the caller's to pick rather than a property of the map.
    func isCollapsed(_ k: String, default fallback: Bool = false) -> Bool { map[k] ?? fallback }

    func setCollapsed(_ k: String, _ value: Bool) {
        map[k] = value
        defaults.set(map, forKey: key)
    }
}
