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
    /// The prompt templates the settings page edits and the popup lists. Built here
    /// rather than in `ContentView` for the same reason `router` is: ⌘P and the app
    /// menu item are declared in the scene's `commands`, which cannot reach a view's
    /// `@State`, so the store they read has to live above the window.
    @State private var promptTemplates = PromptTemplateStore()
    /// Whether the prompt-template popup is up. Owned here for the same reason
    /// `promptTemplates` is: ⌘P and the app-menu item that flip it are declared in
    /// `commands` below, which cannot reach a view's `@State`.
    @State private var promptTemplatePresentation = PromptTemplatePresentation()

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
                        bells: bells, router: router, promptTemplates: promptTemplates,
                        promptTemplatePresentation: promptTemplatePresentation)
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
            // Declared between Settings and Group, and anchored `after: .appSettings`
            // like Group, so SwiftUI stacks the three same-anchor groups in this
            // order: the item lands between them, where the issue's menu shows it.
            PromptTemplatesCommand(presentation: promptTemplatePresentation)
            GroupCommand(store: store)
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

/// The app menu's "Prompt templates" item and its ⌘P, which open the picker over the
/// window's pane.
///
/// A `Commands` type of its own, like `SettingsCommand`, so it can read `openWindow`
/// and hold the app-owned presentation flag: the item is declared in `commands`, which
/// cannot reach a view's `@State`, so the flag it flips lives above the window. Opening
/// reuses the same reopen-then-activate the Settings item does, because the popup is a
/// sheet on the main window and there has to be a main window to put it on.
struct PromptTemplatesCommand: Commands {
    let presentation: PromptTemplatePresentation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Prompt templates") {
                openWindow(id: WiettyApp.mainWindowID)
                NSApp.activate()
                presentation.show()
            }
            .keyboardShortcut("p", modifiers: .command)
        }
    }
}

/// The app menu's Group submenu, which picks the active group and so filters the
/// sidebar to the workspaces filed under it. "All" clears the filter.
///
/// A `Commands` type of its own, like `SettingsCommand`, so it can hold the app-owned
/// store: a submenu declared in `.commands` cannot reach a view's `@State`, so the
/// state it shares with the sidebar is owned above the window. Its body re-reads the
/// observable store, so a group added in Settings appears here without a relaunch.
struct GroupCommand: Commands {
    let store: ProjectStore

    var body: some Commands {
        // After the Settings item, where the issue's menu shows it. The submenu is
        // present even with no groups yet: it then offers only "All", which points at
        // where groups are made.
        CommandGroup(after: .appSettings) {
            Menu("Group") {
                ForEach(WorkspaceGroupMenu.items(groups: store.groups,
                                                 selected: store.selectedGroupId)) { item in
                    Button {
                        store.selectedGroupId = item.id
                    } label: {
                        // The checkmark marks the active group. Driven by the tested
                        // `isSelected` rather than a second comparison here.
                        if item.isSelected {
                            Label(item.title, systemImage: "checkmark")
                        } else {
                            Text(item.title)
                        }
                    }
                }
            }
        }
    }
}
