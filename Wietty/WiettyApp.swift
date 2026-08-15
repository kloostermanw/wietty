import SwiftUI
import AppKit
import WiettyShared

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
    /// What the window's pane is showing over its terminal. See `PaneRouter`.
    @State private var router = PaneRouter()

    /// The main window's scene id, shared by the three places that reopen or focus it.
    /// A literal repeated per site fails silently at runtime when one of them is
    /// mistyped: `openWindow` finds no scene and nothing happens.
    static let mainWindowID = "main"

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
        Window("Wietty", id: Self.mainWindowID) {
            ContentView(store: store, terminals: terminals,
                        remoteConnections: remoteConnections, remoteWorkspaces: remoteWorkspaces,
                        bells: bells, router: router)
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
            SettingsCommand(router: router)
        }
        // No `Settings` scene. There is one window, and settings is one of the things
        // its pane can show, so a second window would be the only part of the app that
        // opened one.
    }
}

/// The app menu's Settings item, which puts the panel in the window's pane rather
/// than opening a window.
///
/// A `Commands` type of its own so it can read `openWindow` from the environment. An
/// `App` can hold `@Environment`, so that is not the constraint; a `Commands` value
/// is simply the smallest thing that can, and it keeps the scene declaration above
/// down to one line.
struct SettingsCommand: Commands {
    let router: PaneRouter
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replacing rather than adding: removing the `Settings` scene took the
        // standard item with it, and this is the placement it had, so the item stays
        // where a Mac user looks for it and keeps ⌘, to itself.
        CommandGroup(replacing: .appSettings) {
            // Shows rather than toggles, unlike the gear. ⌘, is how a Mac opens
            // settings, and a second press closing them again is not what the rest of
            // the system does. The gear is the toggle, and it is the one on screen
            // while the panel is up.
            Button("Settings…") {
                // The main window can be closed while the app runs, and settings put
                // in a pane nobody can see is not an answer. `openWindow` reopens a
                // closed `Window` scene and focuses an open one, the same way a
                // tapped bell notification gets back to it.
                openWindow(id: WiettyApp.mainWindowID)
                NSApp.activate()
                router.show(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
