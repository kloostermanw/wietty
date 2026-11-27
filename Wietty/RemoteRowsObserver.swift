import Foundation
import Combine
import WiettyShared

/// Hands every connected Mac's rows to whoever follows them, at each pushed snapshot.
///
/// Subscribes with Combine rather than from a view for the reason `RemoteBellObserver`
/// does: the sidebar is a `LazyVStack`, so a remote section scrolled out of view is not
/// built, and the pane's selection has to follow a restarted row whether or not its
/// section is on screen.
///
/// Holds no rule of its own. `PaneRouter.remoteRowsChanged` decides what a snapshot
/// means for the selection.
@MainActor
final class RemoteRowsObserver {
    /// One subscription per connection, with the store it listens to, plus one for
    /// the set of connections itself. The store is kept because the controller puts a
    /// new one under the same id when a connection is edited (name, host, port or
    /// token), and the old one never publishes again.
    private var perStore: [UUID: (store: RemoteWorkspaceStore, subscription: AnyCancellable)] = [:]
    private var stores: AnyCancellable?
    private let onRows: (UUID, [RemoteRow]) -> Void

    /// - Parameter onRows: called with a connection and its rows: once with what a
    ///   store holds when it is first seen (nothing, for a store just made, also the
    ///   one that replaces an edited connection's), then at every snapshot.
    init(onRows: @escaping (UUID, [RemoteRow]) -> Void) {
        self.onRows = onRows
    }

    /// Starts watching, and keeps watching as connections are added and removed.
    ///
    /// Idempotent: called from `ContentView.task`, which can run again for the same
    /// window.
    func start(controller: RemoteWorkspacesController) {
        guard stores == nil else { return }
        stores = controller.$stores
            .sink { [weak self] stores in self?.resubscribe(to: stores) }
    }

    private func resubscribe(to stores: [UUID: RemoteWorkspaceStore]) {
        for id in perStore.keys where stores[id] == nil {
            perStore.removeValue(forKey: id)
        }
        for (id, store) in stores where perStore[id]?.store !== store {
            let subscription = store.$workspaces
                .sink { [weak self] workspaces in
                    self?.onRows(id, RemoteRow.rows(in: workspaces))
                }
            perStore[id] = (store, subscription)
        }
    }
}
