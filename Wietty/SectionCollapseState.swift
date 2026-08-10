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

    func isCollapsed(_ k: String) -> Bool { map[k] ?? false }

    func setCollapsed(_ k: String, _ value: Bool) {
        map[k] = value
        defaults.set(map, forKey: key)
    }
}
