import Foundation
import Testing
import WiettyShared
@testable import Wietty

/// The two observers of connected Macs' snapshots, on a real connection list and a
/// real controller: which store each listens to as connections are added, edited and
/// removed. The stores point at a port nothing listens on; snapshots are applied by
/// hand.
@MainActor
@Suite struct RemoteObserverTests {
    private final class MemorySecrets: SecretStore {
        private var secrets: [String: String] = [:]
        func secret(for key: String) -> String? { secrets[key] }
        func setSecret(_ value: String, for key: String) { secrets[key] = value }
        func removeSecret(for key: String) { secrets[key] = nil }
    }

    /// What an observer was called with, in order.
    private final class Calls<Value> {
        var values: [Value] = []
    }

    private let connection = RemoteConnection(id: UUID(), name: "Studio", host: "127.0.0.1",
                                              port: 9, token: "not-a-token")
    private let row = UUID()

    private func controller() -> (RemoteConnectionsStore, RemoteWorkspacesController) {
        let connections = RemoteConnectionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                                 secretStore: MemorySecrets())
        connections.add(connection)
        return (connections, RemoteWorkspacesController(connections: connections))
    }

    /// A snapshot with one workspace and one row carrying `session`.
    private func snapshot(session: String, attention: Bool = false) -> String {
        """
        {"workspaces":[{"id":"\(UUID().uuidString)","name":"site","terminals":[\
        {"id":"\(row.uuidString)","session_id":"\(session)","label":"zsh",\
        "needs_attention":\(attention)}]}]}
        """
    }

    /// Renames the connection the way Settings does: update, then sync. The
    /// controller replaces the store under the same id.
    private func rename(_ connections: RemoteConnectionsStore,
                        _ controller: RemoteWorkspacesController) throws -> RemoteWorkspaceStore {
        let before = try #require(controller.stores[connection.id])
        var edited = connection
        edited.name = "Studio 2"
        connections.update(edited)
        controller.sync()
        let after = try #require(controller.stores[connection.id])
        #expect(after !== before)
        return after
    }

    // MARK: - Rows

    @Test func rowsOfEverySnapshotAreHandedOver() throws {
        let (_, controller) = controller()
        let calls = Calls<[RemoteRow]>()
        let observer = RemoteRowsObserver { _, rows in calls.values.append(rows) }
        observer.start(controller: controller)
        controller.sync()
        let store = try #require(controller.stores[connection.id])
        store.apply(snapshotText: snapshot(session: "old"))
        #expect(calls.values.last == [RemoteRow(id: row, sessionId: "old")])
        store.apply(snapshotText: snapshot(session: "new"))
        #expect(calls.values.last == [RemoteRow(id: row, sessionId: "new")])
    }

    /// An edited connection gets a new store under its old id. The observer has to
    /// listen to that one, or the selection stops following the connection's rows
    /// until the app is launched again.
    @Test func rowsOfAnEditedConnectionsNewStoreAreHandedOver() throws {
        let (connections, controller) = controller()
        let calls = Calls<[RemoteRow]>()
        let observer = RemoteRowsObserver { _, rows in calls.values.append(rows) }
        observer.start(controller: controller)
        controller.sync()
        let first = try #require(controller.stores[connection.id])
        first.apply(snapshotText: snapshot(session: "old"))
        let second = try rename(connections, controller)
        second.apply(snapshotText: snapshot(session: "new"))
        #expect(calls.values.last == [RemoteRow(id: row, sessionId: "new")])
        // The store that was replaced is no longer listened to.
        let count = calls.values.count
        first.apply(snapshotText: snapshot(session: "stale"))
        #expect(calls.values.count == count)
    }

    @Test func aRemovedConnectionsRowsAreNoLongerHandedOver() throws {
        let (connections, controller) = controller()
        let calls = Calls<[RemoteRow]>()
        let observer = RemoteRowsObserver { _, rows in calls.values.append(rows) }
        observer.start(controller: controller)
        controller.sync()
        let store = try #require(controller.stores[connection.id])
        connections.remove(id: connection.id)
        controller.sync()
        let count = calls.values.count
        store.apply(snapshotText: snapshot(session: "late"))
        #expect(calls.values.count == count)
    }

    // MARK: - Bells

    @Test func aBellOfAConnectionIsReported() throws {
        let (_, controller) = controller()
        let calls = Calls<RemoteBellDiff>()
        let observer = RemoteBellObserver { _, diff in calls.values.append(diff) }
        observer.start(controller: controller)
        controller.sync()
        let store = try #require(controller.stores[connection.id])
        store.apply(snapshotText: snapshot(session: "s"))
        store.apply(snapshotText: snapshot(session: "s", attention: true))
        #expect(calls.values.last?.ringing.map(\.sessionId) == ["s"])
    }

    /// The same for bells: after an edit the new store is the one that rings.
    @Test func aBellOfAnEditedConnectionsNewStoreIsReported() throws {
        let (connections, controller) = controller()
        let calls = Calls<RemoteBellDiff>()
        let observer = RemoteBellObserver { _, diff in calls.values.append(diff) }
        observer.start(controller: controller)
        controller.sync()
        let first = try #require(controller.stores[connection.id])
        first.apply(snapshotText: snapshot(session: "s"))
        let second = try rename(connections, controller)
        second.apply(snapshotText: snapshot(session: "s"))
        let before = calls.values.count
        second.apply(snapshotText: snapshot(session: "s", attention: true))
        #expect(calls.values.count == before + 1)
        #expect(calls.values.last?.ringing.map(\.sessionId) == ["s"])
        // The store that was replaced is no longer listened to.
        let count = calls.values.count
        first.apply(snapshotText: snapshot(session: "s", attention: true))
        #expect(calls.values.count == count)
    }

    /// A store just made holds no snapshot. That nothing is not the connection's first
    /// snapshot: the real first one is, and it is adopted in silence, so a Mac whose
    /// agent has been waiting for an hour is not announced as news at launch.
    @Test func theFirstSnapshotOfAConnectionIsAdoptedInSilence() throws {
        let (_, controller) = controller()
        let calls = Calls<RemoteBellDiff>()
        let observer = RemoteBellObserver { _, diff in calls.values.append(diff) }
        observer.start(controller: controller)
        controller.sync()
        let store = try #require(controller.stores[connection.id])
        store.apply(snapshotText: snapshot(session: "s", attention: true))
        #expect(calls.values.isEmpty)
    }
}
