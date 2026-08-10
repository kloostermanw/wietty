import Foundation
import Combine
import ItermplexShared

/// Watches every connected Mac's snapshots for bells.
///
/// Subscribes with Combine rather than from a view, and that is a correctness
/// requirement rather than a preference: the sidebar is a `LazyVStack`, so a remote
/// section scrolled out of view is not built, and a `RemoteSectionView` that never
/// runs would never notice a bell. Notifications are exactly the feature that has to
/// work while nobody is looking.
///
/// Holds no bell logic of its own. `RemoteBellWatcher` decides what changed, and the
/// caller decides what to do about it.
@MainActor
final class RemoteBellObserver {
    private var watcher = RemoteBellWatcher()
    /// One subscription per connection, plus one for the set of connections itself.
    private var perStore: [UUID: AnyCancellable] = [:]
    private var stores: AnyCancellable?
    private let onDiff: (UUID, RemoteBellDiff) -> Void

    /// - Parameter onDiff: called with the connection and what changed, and never
    ///   with an empty diff, so a caller cannot be woken for nothing.
    init(onDiff: @escaping (UUID, RemoteBellDiff) -> Void) {
        self.onDiff = onDiff
    }

    /// Starts watching, and keeps watching as connections are added and removed.
    ///
    /// Idempotent: called from `ContentView.task`, which can run again for the same
    /// window, and re-subscribing would otherwise double every notification.
    func start(controller: RemoteWorkspacesController) {
        guard stores == nil else { return }
        stores = controller.$stores
            .sink { [weak self] stores in self?.resubscribe(to: stores) }
    }

    private func resubscribe(to stores: [UUID: RemoteWorkspaceStore]) {
        // Connections that went. Their watcher state goes too, so one removed and
        // added again is silent rather than announcing its backlog.
        for id in perStore.keys where stores[id] == nil {
            perStore.removeValue(forKey: id)
            watcher.forget(connection: id)
        }
        for (id, store) in stores where perStore[id] == nil {
            perStore[id] = store.$workspaces
                .sink { [weak self] workspaces in
                    self?.apply(connection: id, workspaces: workspaces)
                }
        }
    }

    private func apply(connection: UUID, workspaces: [RemoteWorkspace]) {
        let diff = watcher.diff(connection: connection,
                                flagged: RemoteBellWatcher.flagged(in: workspaces))
        guard !diff.isEmpty else { return }
        onDiff(connection, diff)
    }
}
