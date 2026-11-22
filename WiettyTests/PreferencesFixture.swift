import Foundation
import WiettyCore
@testable import Wietty

/// A store and the `UIPreferences` that shares its settings writer.
///
/// The two are built together everywhere in the app, because the preferences load
/// from what the store read at launch and write through the writer the store owns.
/// A test that wants either usually wants both wired the same way, and wiring it by
/// hand in thirty places is thirty chances to wire it differently.
@MainActor
struct SettingsFixture {
    let store: ProjectStore
    let preferences: UIPreferences

    init(defaults: UserDefaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!,
         config: WiettyConfigFile? = nil,
         service: TerminalService = FakeTerminalService()) {
        let store = ProjectStore(defaults: defaults, config: config, service: service)
        self.store = store
        self.preferences = UIPreferences(
            launch: store.launch,
            writer: store.settingsWriter,
            knownGroupIds: { [weak store] in Set(store?.groups.map(\.id) ?? []) })
    }
}
