import Foundation
import Observation

/// Tracks what the sidebar has collapsed: each section (Local and every remote
/// connection) and each remote workspace card. Backed by an `@Observable`
/// stored property so toggling one triggers SwiftUI view invalidation; changes
/// are also persisted to `UserDefaults` so collapse survives relaunch.
///
/// One map for both, since they differ only in how a key is built: a section
/// passes `"local"` or `"remote-<connectionId>"`, a card passes
/// `RemoteSectionView.cardKey(connectionId:workspaceId:)`. Local workspace cards
/// are the exception and are not here at all; their collapse belongs to the
/// workspace itself and is saved with it by `ProjectStore.toggleCollapsed`.
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
    /// Section headers take the parameter's own default and start open. A remote
    /// workspace card passes `true` and starts collapsed, because a connection
    /// serving a dozen workspaces must not fill the sidebar the moment it
    /// connects. Which side an untoggled key starts on is therefore the caller's
    /// to pick rather than a property of the map, which holds nothing for it.
    func isCollapsed(_ k: String, default fallback: Bool = false) -> Bool { map[k] ?? fallback }

    func setCollapsed(_ k: String, _ value: Bool) {
        map[k] = value
        defaults.set(map, forKey: key)
    }
}
