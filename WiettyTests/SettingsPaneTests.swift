import Testing
import AppKit
import SwiftUI
import WiettyShared
@testable import Wietty

/// What Settings has to survive now that it is the pane rather than a window of its
/// own.
///
/// A window sized itself to the form. The pane's width is a divider the user drags
/// and its height is the window's, so the panel has to fill what it is offered and
/// carry the same floor as everything else the pane can hold. Measured through
/// `RightTerminalView` rather than `SettingsView` directly, because the branch that
/// puts the panel in the pane is part of what is being asserted, and measured with
/// `NSHostingController` the way `LocalTerminalViewTests` measures the pane, which
/// needs neither a window nor a Metal device.
@MainActor
@Suite struct SettingsPaneTests {
    /// A pane over an empty store: remote access off, no connections.
    private func pane(_ selection: PaneSelection) -> RightTerminalView {
        pane(selection, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func pane(_ selection: PaneSelection, defaults: UserDefaults) -> RightTerminalView {
        let connections = RemoteConnectionsStore(defaults: defaults)
        return RightTerminalView(
            store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
            stack: GhosttyStack(host: FakeSurfaceHost(), helperPath: "/usr/bin/true"),
            remoteConnections: connections,
            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
            bells: notifier(),
            desktopNotifications: setting(),
            ghosttyColors: colors(),
            selection: selection)
    }

    /// A notifier over a fake centre. The real one needs an authorized bundle and
    /// would put a permission prompt on screen during a test run, which is the whole
    /// reason `NotificationSink` is a protocol.
    private func notifier() -> BellNotifier {
        BellNotifier(sink: FakeNotificationSink())
    }

    private func setting(overriding: Bool = false) -> DesktopNotificationSetting {
        .fake(overriding: overriding)
    }

    /// Colours over a fake host and a temporary file, so a render never reads or
    /// writes the developer's own `~/.config/wietty/ghostty.cfg`.
    private func colors() -> GhosttyColorSettings {
        GhosttyColorSettings(host: FakeSurfaceHost(), file: .temporary())
    }

    private func sizeOffered<V: View>(_ view: V, _ size: NSSize) -> NSSize {
        NSHostingController(rootView: view).sizeThatFits(in: size)
    }

    /// The panel takes the width it is given. It was a fixed 380 points as a window,
    /// which in a column the user drags to any width would leave dead space beside
    /// it.
    @Test func settingsFillsTheWidthItIsOffered() {
        #expect(sizeOffered(pane(.settings), NSSize(width: 900, height: 800)).width == 900)
    }

    /// And the height, by accepting an offer smaller than its content rather than
    /// asking for the height its form wants. The window's minimum height is built from
    /// the pane's floor, so a panel that demanded its content height would resize the
    /// window every time it is opened.
    ///
    /// The unbounded measurement is what makes the equality mean something: it shows
    /// the content really is taller than the offer, so `== 300` is the panel yielding
    /// rather than the form happening to fit. It still cannot tell scrolling from
    /// clipping, which is a manual check.
    @Test func settingsYieldsToAHeightSmallerThanItsContent() {
        let unbounded = sizeOffered(pane(.settings),
                                    NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude))
        #expect(unbounded.height > 300)
        #expect(sizeOffered(pane(.settings), NSSize(width: 900, height: 300)).height == 300)
    }

    /// The same floor the other things in the pane carry, so what is on screen cannot
    /// change how small the window can get.
    @Test func settingsKeepsThePaneMinimumInAWindowSmallerThanIt() {
        let size = sizeOffered(pane(.settings), NSSize(width: 100, height: 100))
        #expect(Double(size.width) == SidebarWidth.paneMinimum)
        #expect(Double(size.height) == SidebarWidth.paneMinimumHeight)
    }

    /// Five segments across a 480 point pane is about 90 points each, and
    /// "Notifications" does not fit in that, so the control has to give up label
    /// text rather than width. If it ever asks for its ideal width instead, the pane
    /// floor moves and the window's minimum width moves with it, which is a change
    /// to the whole window made by a control in one panel.
    @Test func theTabControlDoesNotWidenThePaneFloor() {
        let width = SidebarWidth.paneMinimum
        let size = sizeOffered(pane(.settings),
                               NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        #expect(Double(size.width) == width)
    }

    /// The bar above the pane is the way in that is inside the window. The app menu's
    /// item and ⌘, are the other two, and the window has no title bar of its own.
    ///
    /// The help text is asserted too: the gear is icon only, so that string is the
    /// whole of its name in the tooltip and in `accessibilityLabel`.
    @Test func theBarOffersSettingsAndNothingElse() {
        let buttons = NavBarView.trailingButtons(openSettings: {})
        #expect(buttons.map(\.system) == ["gearshape"])
        #expect(buttons.map(\.help) == ["Settings"])
    }

    /// The spec's id has to survive a redraw. A fresh `UUID` per pass, which is what
    /// this was, gives `ForEach` a new identity every time the bar redraws, so the
    /// button is rebuilt rather than updated and a redraw between mouse down and mouse
    /// up drops the click. The bar redraws on every selection change and every git poll.
    @Test func aButtonSpecKeepsItsIdentityAcrossRebuilds() {
        let first = NavBarView.trailingButtons(openSettings: {})
        let second = NavBarView.trailingButtons(openSettings: {})
        #expect(first.map(\.id) == second.map(\.id))
    }

    /// Forces a real render pass over the whole panel, so a construction or wiring
    /// crash anywhere in it surfaces here rather than the first time it is opened.
    @Test func thePaneRendersSettings() {
        let renderer = ImageRenderer(content: pane(.settings).frame(width: 600, height: 800))
        #expect(renderer.nsImage != nil)
    }

    /// The tabs split the panel into five subtrees and only the one that is up gets
    /// built, so the render above now covers a fifth of it. Every tab is rendered
    /// here instead, which is what keeps a crash in a tab nobody opened during
    /// development from waiting for a user to find it.
    ///
    /// Rendered through `SettingsView` rather than the pane, because the tab is the
    /// thing being varied and `RightTerminalView` has no opinion on it.
    @Test func everyTabRenders() {
        for tab in SettingsTab.allCases {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let connections = RemoteConnectionsStore(defaults: defaults)
            let view = SettingsView(
                store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
                remoteConnections: connections,
                remoteWorkspaces: RemoteWorkspacesController(connections: connections),
                bells: notifier(),
                desktopNotifications: setting(),
                ghosttyColors: colors(),
                tab: tab)
            let renderer = ImageRenderer(content: view.frame(width: 600, height: 800))
            #expect(renderer.nsImage != nil, "\(tab.title) failed to render")
        }
    }

    /// The General tab now carries the two colour sections, and neither is reached by
    /// an empty store: the app colours draw their reset button only once a colour is
    /// set, and the terminal colours draw theirs only when the override file carries
    /// one. Both are set here so the render covers the wells and their reset buttons.
    @Test func theGeneralTabRendersWithColoursSet() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connections = RemoteConnectionsStore(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.sidebarColors.background = ColorHex.color(from: "#303446")
        store.sidebarColors.activeTerminalRowForeground = ColorHex.color(from: "#c6d0f5")
        let colours = GhosttyColorSettings(host: FakeSurfaceHost(), file: .temporary())
        colours.setColor(GhosttyOverrideFile.ColorKey.background, to: ColorHex.color(from: "#303446"))
        let view = SettingsView(
            store: store,
            remoteConnections: connections,
            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
            bells: notifier(),
            desktopNotifications: setting(),
            ghosttyColors: colours,
            tab: .general)
        #expect(ImageRenderer(content: view.frame(width: 600, height: 1200)).nsImage != nil)
    }

    /// The Notifications tab draws four different things depending on what the
    /// notification centre answered and what the last test did, and `everyTabRenders`
    /// reaches only the "nothing known yet" one: `task` does not run under
    /// `ImageRenderer`, so the permission is never read there. Both are passed in
    /// here instead, which is the same reason `SettingsView.init` takes a `tab:`.
    ///
    /// The permission button and the failure label are the two branches worth the
    /// trouble: one appears in exactly one state, the other only after a refusal.
    @Test func theNotificationsTabRendersInEveryState() {
        let refusal = "Notifications are not allowed for this application"
        let states: [(NotificationPermission?, BellNotifier.TestResult?, String?)] = [
            (nil, nil, nil),
            (.notAsked, nil, nil),
            (.granted, .posted, nil),
            (.denied, .failed(reason: refusal), nil),
            // The one the button being pressed and nothing happening produces: still
            // not asked, because macOS turned the request down without a prompt.
            (.notAsked, nil, refusal)
        ]
        for (permission, result, failure) in states {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let view = Form {
                NotificationSettings(
                    store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
                    bells: notifier(),
                    desktopNotifications: setting(),
                    permission: permission,
                    testResult: result,
                    requestFailure: failure)
            }
            .formStyle(.grouped)
            let renderer = ImageRenderer(content: view.frame(width: 600, height: 900))
            #expect(renderer.nsImage != nil, "\(String(describing: permission)) failed to render")
        }
    }

    /// The branch that explains the override draws. It only appears when Wietty's
    /// file and the user's own Ghostty config disagree, which is a state no other
    /// render test reaches, so without this the notice would first be seen by
    /// somebody who had already been confused by the toggle.
    @Test func theTabRendersTheOverrideNotice() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let setting = setting(overriding: true)
        #expect(setting.overridesUserConfig)
        let view = Form {
            NotificationSettings(store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
                                 bells: notifier(),
                                 desktopNotifications: setting, permission: .granted)
        }
        .formStyle(.grouped)
        #expect(ImageRenderer(content: view.frame(width: 600, height: 900)).nsImage != nil)
    }

    /// The preview button's failure is drawn, rather than leaving a button that makes
    /// no sound and says nothing. `play()` is what decides it, and the caller used to
    /// discard the answer.
    @Test func aSoundThatCannotBePlayedReportsItself() {
        // Nothing is installed under this name, so `NSSound(named:)` finds no file.
        #expect(BellSound.named("NoSuchSoundAnywhere").play() == false)
        #expect(BellSound.silent.play() == false)
        #expect(BellSound.systemDefault.play() == true)
    }

    /// A sound the picker does not offer still has to select, or a macOS release that
    /// drops a sound leaves the control blank rather than saying which sound is gone.
    @Test func theSoundPickerRendersASoundItDoesNotOffer() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.bellSound = .named("SoundFromAnotherMac")
        let view = Form {
            NotificationSettings(store: store, bells: notifier(),
                                 desktopNotifications: setting(), permission: .granted)
        }
        .formStyle(.grouped)
        #expect(ImageRenderer(content: view.frame(width: 600, height: 900)).nsImage != nil)
    }

    /// The same, for the two sub-trees an empty store never reaches: the URL and QR
    /// block behind `remoteEnabled`, and `RemoteConnectionRow`. Both draw inside the
    /// main window now, so a crash in either takes the window rather than a secondary
    /// one. `LocalNetwork.primaryIPv4()` returning nil on a machine with no interface
    /// picks the other branch of that block, which is also worth passing through.
    ///
    /// On the Remote tab explicitly: both live there, and the panel opens on General,
    /// so without naming the tab this would render neither and still pass.
    @Test func settingsRendersWithRemoteAccessOnAndAConnection() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let connections = RemoteConnectionsStore(defaults: defaults)
        connections.add(RemoteConnection(id: UUID(), name: "Office Mac",
                                         host: "192.168.1.20", port: 7434, token: "t"))
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.remoteEnabled = true
        let view = SettingsView(
            store: store,
            remoteConnections: connections,
            remoteWorkspaces: RemoteWorkspacesController(connections: connections),
            bells: notifier(),
            desktopNotifications: setting(),
            ghosttyColors: colors(),
            tab: .remote)
        let renderer = ImageRenderer(content: view.frame(width: 600, height: 1200))
        #expect(renderer.nsImage != nil)
    }

    /// The app menu's item, which is the one part of the way in that no pure type can
    /// answer for.
    ///
    /// Possible only because `WiettyTests` is hosted by the app itself (`TEST_HOST`),
    /// so the real `WiettyApp` has launched and SwiftUI has installed its menu before
    /// this runs. It pins the three things deleting the `Settings` scene put at risk:
    /// that the item survived `CommandGroup(replacing: .appSettings)`, that it kept ⌘,,
    /// and that there is exactly one of it, so re-adding a `Settings` scene later would
    /// fail here rather than double bind the shortcut. It cannot press the item: the
    /// test has no handle on the app's own `PaneRouter`.
    @Test func theAppMenuOffersSettingsOnCommandComma() {
        let items = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.title == "Settings…" } ?? []
        #expect(items.count == 1)
        #expect(items.first?.keyEquivalent == ",")
        #expect(items.first?.keyEquivalentModifierMask == .command)
    }

    /// The app menu's Group submenu, which the sidebar filter reads its selection
    /// from. The same integration check as Settings, and possible for the same reason:
    /// `WiettyTests` is hosted by the app (`TEST_HOST`), so the real `WiettyApp` has
    /// installed its menu before this runs. It pins that `GroupCommand` landed one
    /// "Group" submenu in the menu bar; no pure type can answer for the wiring itself.
    @Test func theAppMenuOffersAGroupSubmenu() {
        let items = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.title == "Group" } ?? []
        #expect(items.count == 1)
        #expect(items.first?.submenu != nil)
    }

    /// The bar itself, which this change gave a `Button`, a `ForEach` and a
    /// conditional `foregroundStyle`. Both states, because the tint is the branch.
    @Test func theBarRendersWithAndWithoutTheSettingsPanelUp() {
        for selection in [PaneSelection.settings, .none] {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            let connections = RemoteConnectionsStore(defaults: defaults)
            let bar = NavBarView(
                store: ProjectStore(defaults: defaults, service: FakeTerminalService()),
                remoteWorkspaces: RemoteWorkspacesController(connections: connections),
                selection: selection,
                onOpenSettings: {})
            let renderer = ImageRenderer(content: bar.frame(width: 600))
            #expect(renderer.nsImage != nil)
        }
    }
}
