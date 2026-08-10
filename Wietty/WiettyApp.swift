import SwiftUI
import ItermplexShared

@main
struct WiettyApp: App {
    @State private var terminals: TerminalStack
    @State private var store: ProjectStore
    @State private var updates = UpdateService()
    @StateObject private var remoteConnections: RemoteConnectionsStore
    @StateObject private var remoteWorkspaces: RemoteWorkspacesController
    /// Built here rather than in `ContentView` because of what tapping a
    /// notification does when the app is not running: the system delivers that tap as
    /// soon as a notification delegate exists, which is during launch, and a delegate
    /// installed later from a view's `task` would miss it. `SystemNotificationSink`
    /// holds the tap until `ContentView` is ready for it.
    @State private var bells = BellNotifier(sink: SystemNotificationSink())

    init() {
        let stack = TerminalStack()
        _terminals = State(wrappedValue: stack)
        // The job poll needs the live service, which only exists once the stack is
        // built, so the store is handed a closure rather than the service itself.
        _store = State(wrappedValue: ProjectStore(service: stack.service,
                                                  jobEvents: stack.ghostty.pollJobs))
        let connections = RemoteConnectionsStore()
        _remoteConnections = StateObject(wrappedValue: connections)
        _remoteWorkspaces = StateObject(wrappedValue: RemoteWorkspacesController(connections: connections))
    }

    var body: some Scene {
        Window("Wietty", id: "main") {
            ContentView(store: store, terminals: terminals,
                        remoteConnections: remoteConnections, remoteWorkspaces: remoteWorkspaces,
                        bells: bells)
                .preferredColorScheme(.dark)
                .updateAlerts(updates)
                .task {
                    await updates.checkForUpdates(userInitiated: false)
                    await updates.runPeriodicChecks()
                }
        }
        .windowStyle(.hiddenTitleBar)
        // Wide enough for both halves: 300 points would be narrower than their own
        // minimums (240 and 480) and would open clamped to the smallest terminal the
        // pane allows. Only the default: a window the user has already sized keeps
        // its saved frame.
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.checkForUpdates(userInitiated: true) }
                }
            }
        }

        Settings {
            SettingsView(store: store, remoteConnections: remoteConnections, remoteWorkspaces: remoteWorkspaces)
        }
    }
}
