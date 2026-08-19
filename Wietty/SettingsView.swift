import SwiftUI
import WiettyShared

struct SettingsView: View {
    @Bindable var store: ProjectStore
    @ObservedObject var remoteConnections: RemoteConnectionsStore
    @ObservedObject var remoteWorkspaces: RemoteWorkspacesController
    /// The app's own notifier, not one built here: the permission the Notifications
    /// tab reports has to be the permission the bells are subject to.
    let bells: BellNotifier
    /// The app's own setting, for the same reason `bells` is the app's own notifier:
    /// a toggle reporting a config the live surfaces are not running on would be
    /// worse than no toggle.
    let desktopNotifications: DesktopNotificationSetting
    /// The terminal's colours, for the same reason: the wells write the file the live
    /// surfaces reload, so this has to be the app's own instance.
    let ghosttyColors: GhosttyColorSettings

    /// View state, not a preference. The panel is destroyed when the pane shows
    /// anything else, so this resets on the way back in, which is what a user who
    /// left through a terminal row expects. Persisting it would reopen settings on
    /// whatever they last touched, months later.
    @State private var tab = SettingsTab.default

    // Held here rather than inside the tab's own view, so a half typed connection
    // survives a look at another tab. Leaving the panel altogether still discards
    // it: the pane destroys the panel when it shows anything else.
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "7434"
    @State private var newToken = ""
    // The same, for the agent being added on the Agents tab.
    @State private var newAgentName = ""
    @State private var newAgentCommand = ""
    @State private var newAgentArguments = ""
    // And for the group being added on the General tab.
    @State private var newGroupName = ""

    /// - Parameter tab: which tab is up. Defaults to the one the panel opens on;
    ///   only the tests pass anything else, because only one tab's subtree is built
    ///   at a time and a render test that could not choose would cover one fifth of
    ///   the panel while looking like it covered all of it.
    init(store: ProjectStore,
         remoteConnections: RemoteConnectionsStore,
         remoteWorkspaces: RemoteWorkspacesController,
         bells: BellNotifier,
         desktopNotifications: DesktopNotificationSetting,
         ghosttyColors: GhosttyColorSettings,
         tab: SettingsTab = .default) {
        _store = Bindable(wrappedValue: store)
        _remoteConnections = ObservedObject(wrappedValue: remoteConnections)
        _remoteWorkspaces = ObservedObject(wrappedValue: remoteWorkspaces)
        self.bells = bells
        self.desktopNotifications = desktopNotifications
        self.ghosttyColors = ghosttyColors
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Outside the form on purpose: the form scrolls, and a control that
            // scrolled with it would be off screen exactly when a user who has read
            // to the bottom of one tab wants the next.
            Picker("Settings tab", selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            content
        }
        // No width of its own. As a window it was a fixed 380 points, which in a
        // column whose width is a divider the user drags would leave dead space
        // beside it. The grouped form scrolls, so the height it is offered is
        // whatever the window has left under the bar and the tab control.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            form {
                badgeSection
                groupsSection
                periodicChecksSection
                colorsSection
                terminalColorsSection
            }
            // Re-read the terminal colours on the way into the tab, the same as the
            // Notifications tab re-reads its own setting and for the same reason: the
            // file is an ordinary one the user can edit while the window is open, so a
            // well showing the launch-time value would be the one place that is wrong
            // about it.
            .task { ghosttyColors.refresh() }
        case .notifications:
            form { NotificationSettings(store: store, bells: bells,
                                        desktopNotifications: desktopNotifications) }
        case .agents:
            form { agentsSection }
        case .remote:
            form {
                remoteAccessSection
                remoteConnectionsSection
            }
        case .mcp:
            form { mcpSection }
        }
    }

    /// The one grouped form every tab with settings in it draws, so the tabs cannot
    /// drift in style or in how they fill the pane.
    ///
    /// The field style is set here rather than at each field for the same reason.
    /// `textFieldStyle` travels down the environment, so this one line reaches every
    /// `TextField` and `SecureField` in every tab, and a field added later gets it
    /// without anyone remembering to. Without it a grouped form draws a field as its
    /// label and its value as plain right aligned text, with no border and no
    /// background of its own: nothing said the value was editable, and an empty field
    /// was invisible, indistinguishable from a caption.
    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var agentsSection: some View {
        Section("Agents") {
            if store.agents.isEmpty {
                Text("No agents. The two \"Add Agent\" entries in a workspace's menu "
                     + "have nothing to offer until there is one here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.agents) { agent in
                AgentRow(agent: agent,
                         onUpdate: { store.updateAgent($0) },
                         onDelete: { store.removeAgent(id: agent.id) })
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $newAgentName)
                TextField("Command", text: $newAgentCommand)
                TextField("Default Arguments", text: $newAgentArguments)
                Button("Add Agent", action: addAgent)
                    .disabled(!newAgent.isValid)
            }
            Text("Each agent is one entry in a workspace's \"Add Agent\" menu. Starting "
                 + "one opens a terminal in that workspace and types the command, "
                 + "followed by its arguments. \"Add Agent with args\" asks for other "
                 + "arguments first, starting from the ones here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var groupsSection: some View {
        Section("Groups") {
            if store.groups.isEmpty {
                Text("No groups. Every workspace shows under \"All\" in the app menu's "
                     + "Group submenu until you make one here and file workspaces under it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.groups) { group in
                GroupRow(group: group,
                         onUpdate: { store.updateGroup($0) },
                         onDelete: { store.removeGroup(id: group.id) })
            }
            HStack {
                TextField("Name", text: $newGroupName)
                Button("Add Group", action: addGroup)
                    .disabled(!newGroup.isValid)
            }
            Text("A group is one entry in the app menu's Group submenu. Pick it there to "
                 + "show only the workspaces filed under it. Assign a workspace to a group "
                 + "from \"Edit workspace…\" in its menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var mcpSection: some View {
        Section {
            portField("MCP server", value: $store.mcpPort)
            if let error = store.mcpStartupError {
                Label("MCP server did not start: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("The loopback TCP port the MCP server listens on. It restarts on the new port as soon as you change it. See docs/mcp.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var remoteAccessSection: some View {
        Section("Remote access (experimental)") {
            Toggle("Enable LAN remote terminal", isOn: $store.remoteEnabled)
            portField("Port", value: $store.remotePort)
            if let error = store.remoteStartupError {
                Label("Server did not start: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if store.remoteEnabled {
                if let ip = LocalNetwork.primaryIPv4() {
                    let url = "http://\(ip):\(store.remotePort)/?token=\(store.remoteToken.value)"
                    Text(url).font(.caption).textSelection(.enabled)
                    if let qr = QRCode.image(from: url) {
                        Image(nsImage: qr).interpolation(.none).resizable()
                            .frame(width: 140, height: 140)
                    }
                } else {
                    Text("No active network interface found.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Serves a browser terminal to other devices on your local network, on the TCP port above. Anyone with this URL can read and type into your sessions. Traffic is unencrypted, so use it only on trusted networks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var remoteConnectionsSection: some View {
        Section("Remote connections") {
            ForEach(remoteConnections.connections) { connection in
                RemoteConnectionRow(
                    connection: connection,
                    onUpdate: { updated in
                        remoteConnections.update(updated)
                        remoteWorkspaces.sync()
                    },
                    onDelete: {
                        remoteConnections.remove(id: connection.id)
                        remoteWorkspaces.sync()
                    }
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $newName)
                TextField("Host", text: $newHost)
                NarrowFieldRow("Port") { TextField("Port", text: $newPort) }
                SecureField("Token", text: $newToken)
                Button("Add connection", action: addConnection)
                    .disabled(!newConnectionIsValid)
            }
            Text("Connect to another Mac running Wietty with its LAN remote terminal enabled. Enter the host, port, and token shown in that Mac's Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var badgeSection: some View {
        Section {
            Toggle("Show workspace name as terminal badge", isOn: $store.showWorkspaceBadge)
            Text("Marks each terminal Wietty opens with its workspace's name. Applies to terminals opened after this is turned on. Currently inert: libghostty exposes no way to set a surface's title.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var periodicChecksSection: some View {
        Section("Periodic checks") {
            intervalStepper("Fast", value: $store.checkIntervals.fast, range: CheckIntervals.fastRange)
            intervalStepper("Normal", value: $store.checkIntervals.normal, range: CheckIntervals.normalRange)
            intervalStepper("Slow", value: $store.checkIntervals.slow, range: CheckIntervals.slowRange)
            Text("Seconds between checks for each tier. Which check runs at which tier depends on context (collapsed vs expanded workspace, pending CI, attention). See docs/periodic-checks.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Wietty's own UI colours. Each well is empty until it is set, and a set colour
    /// shows a reset that clears it back to the default. Persisted to
    /// `~/.config/wietty/config`; the terminal's own colours are the next section.
    @ViewBuilder private var colorsSection: some View {
        Section("Colors") {
            ColorSettingRow("Background", default: Self.defaultBackground,
                            color: $store.sidebarColors.background)
            ColorSettingRow("Foreground", default: Self.defaultForeground,
                            color: $store.sidebarColors.foreground)
            ColorSettingRow("Active workspace background", default: Self.defaultActiveBackground,
                            color: $store.sidebarColors.activeWorkspaceBackground)
            ColorSettingRow("Active workspace foreground", default: Self.defaultForeground,
                            color: $store.sidebarColors.activeWorkspaceForeground)
            ColorSettingRow("Active terminal row background", default: Self.defaultActiveRowBackground,
                            color: $store.sidebarColors.activeTerminalRowBackground)
            ColorSettingRow("Active terminal row foreground", default: Self.defaultForeground,
                            color: $store.sidebarColors.activeTerminalRowForeground)
            Text("Colours for Wietty's own sidebar. A colour left unset keeps the system default; the reset button beside a colour clears it back to that.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The terminal's colours, written to `ghostty.cfg` and reloaded live. These are
    /// libghostty's to apply, so they go through `GhosttyColorSettings` rather than
    /// the store. A row shows the value Wietty is forcing, not what an untouched
    /// terminal resolves to from the user's own theme.
    @ViewBuilder private var terminalColorsSection: some View {
        Section("Ghostty colors") {
            terminalColorRow("Background", key: GhosttyOverrideFile.ColorKey.background,
                             default: .black)
            terminalColorRow("Foreground", key: GhosttyOverrideFile.ColorKey.foreground,
                             default: .white)
            terminalColorRow("Cursor", key: GhosttyOverrideFile.ColorKey.cursor,
                             default: .white)
            terminalColorRow("Cursor text", key: GhosttyOverrideFile.ColorKey.cursorText,
                             default: .black)
            terminalColorRow("Selection background", key: GhosttyOverrideFile.ColorKey.selectionBackground,
                             default: .gray)
            terminalColorRow("Selection foreground", key: GhosttyOverrideFile.ColorKey.selectionForeground,
                             default: .white)
            if let failure = ghosttyColors.writeFailure {
                Label("Could not save that: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("Written to \(ghosttyColors.fileURL.path), which Wietty loads after your own Ghostty config so what is set here wins for Wietty's terminals. Ghostty.app is not affected. A colour left unset keeps your own theme's; the reset button clears one back to that.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One terminal-colour row. The binding does not write the store: it drives
    /// `GhosttyColorSettings`, which writes the file and reloads the live config, so a
    /// plain `@Bindable` binding would skip the reload and leave open terminals stale.
    private func terminalColorRow(_ title: String, key: String, default fallback: Color) -> some View {
        ColorSettingRow(title, default: fallback, color: Binding(
            get: { ghosttyColors.color(for: key) },
            set: { ghosttyColors.setColor(key, to: $0) }
        ))
    }

    // The swatch a well shows before a colour is set. Three are the real current
    // default, so the well previews what the sidebar draws today: the window
    // background, the label colour, and the selected row's own `#292b34`. The active
    // workspace background is the exception, because an unset active card draws no
    // background at all: its swatch is an indicative starting colour rather than a
    // preview of a default there is none of.
    private static let defaultBackground = Color(nsColor: .windowBackgroundColor)
    private static let defaultForeground = Color(nsColor: .labelColor)
    private static let defaultActiveBackground = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    private static let defaultActiveRowBackground = Color(nsColor: SidebarRowBackground.selectedFill)

    private var newConnectionIsValid: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newHost.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(newPort) != nil
            && !newToken.isEmpty
    }

    /// What the fields under the list currently describe. Built rather than stored,
    /// so "is this addable" and "what gets added" cannot disagree.
    private var newAgent: AgentDefinition {
        AgentDefinition(name: newAgentName, command: newAgentCommand,
                        defaultArguments: newAgentArguments)
    }

    private func addAgent() {
        guard newAgent.isValid else { return }
        store.addAgent(newAgent)
        newAgentName = ""
        newAgentCommand = ""
        newAgentArguments = ""
    }

    /// The group the name field currently describes, built rather than stored so "is
    /// this addable" and "what gets added" cannot disagree.
    private var newGroup: WorkspaceGroup { WorkspaceGroup(name: newGroupName) }

    private func addGroup() {
        guard newGroup.isValid else { return }
        store.addGroup(newGroup)
        newGroupName = ""
    }

    private func addConnection() {
        guard let port = Int(newPort) else { return }
        let connection = RemoteConnection(
            id: UUID(),
            name: newName.trimmingCharacters(in: .whitespaces),
            host: newHost.trimmingCharacters(in: .whitespaces),
            port: port,
            token: newToken
        )
        remoteConnections.add(connection)
        remoteWorkspaces.sync()
        newName = ""
        newHost = ""
        newPort = "7434"
        newToken = ""
    }

    private func portField(_ label: String, value: Binding<Int>) -> some View {
        NarrowFieldRow(label) {
            TextField(label, value: value, format: .number.grouping(.never))
        }
    }

    private func intervalStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue) s").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// The Notifications tab: whether macOS lets this app post at all, a way to prove
/// the whole path works, and which sound it makes.
///
/// A view of its own rather than three `@ViewBuilder` properties on `SettingsView`
/// because it is the only tab with state of its own: the permission it read and the
/// verdict on the last test. Both are answers that arrive asynchronously and neither
/// is a preference, so neither belongs on the store.
struct NotificationSettings: View {
    @Bindable var store: ProjectStore
    let bells: BellNotifier
    /// The `desktop-notifications` gate. Drawn on this tab because it is where
    /// somebody looks when notifications are not arriving, and being turned off in
    /// a Ghostty config file is one of the reasons they would not be.
    let desktopNotifications: DesktopNotificationSetting

    /// Nil until the first read comes back, which is a state worth drawing: "not
    /// asked yet" and "we have not looked yet" are different things to say.
    @State private var permission: NotificationPermission?
    @State private var testResult: BellNotifier.TestResult?
    /// Why the last press of the button below achieved nothing, when it did. macOS
    /// turns a request from a bundle it does not accept down in about a millisecond
    /// without showing anyone a prompt, and the state afterwards is the state
    /// before, so without this the button is indistinguishable from a dead one.
    @State private var requestFailure: String?
    /// True when the sound preview beside the picker had nothing to play. A sound
    /// macOS no longer installs is otherwise a button that does nothing, which reads
    /// as broken rather than as a sound that is gone.
    @State private var soundPreviewFailed = false

    /// - Parameters:
    ///   - permission: what the tab starts out believing,
    ///   - testResult: what it starts out reporting, and
    ///   - requestFailure: why the last permission request achieved nothing. All
    ///     three default to the real state, which is "nothing known yet" until the
    ///     `task` below answers; only the tests pass anything else, because these
    ///     decide five of the branches drawn here and a render test that could not
    ///     set them would cover one.
    init(store: ProjectStore, bells: BellNotifier,
         desktopNotifications: DesktopNotificationSetting,
         permission: NotificationPermission? = nil,
         testResult: BellNotifier.TestResult? = nil,
         requestFailure: String? = nil) {
        _store = Bindable(wrappedValue: store)
        self.bells = bells
        self.desktopNotifications = desktopNotifications
        _permission = State(initialValue: permission)
        _testResult = State(initialValue: testResult)
        _requestFailure = State(initialValue: requestFailure)
    }

    var body: some View {
        Section("System notifications") {
            HStack {
                Text("Permission")
                Spacer()
                Label(permissionTitle, systemImage: permissionIcon)
                    .foregroundStyle(permissionColour)
                    .labelStyle(.titleAndIcon)
            }
            // Only while nobody has answered. macOS shows the prompt once per
            // install, so after a denial this button would do nothing at all, and a
            // button that does nothing is worse than the sentence explaining why.
            if permission == .notAsked {
                Button("Allow notifications…") {
                    Task {
                        switch await bells.requestPermission() {
                        case .decided(let answer):
                            permission = answer
                            requestFailure = nil
                        case .failed(let reason):
                            requestFailure = reason
                            permission = await bells.permission()
                        }
                    }
                }
            }
            if let requestFailure {
                Label("macOS turned the request down: \(requestFailure)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                Text("No prompt was shown, so this is not something you answered. It happens when macOS does not accept this copy of the app: a build whose bundle is not signed gets exactly this. Signing it, even ad hoc (`codesign --force --deep --sign - Wietty.app`), is what lets the prompt appear.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if permission == .denied {
                Text("Turn Wietty's notifications back on in System Settings › Notifications. macOS asks only once, so this app cannot ask again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("A terminal notifies you in two ways: the bell character, which every shell rings, and the OSC 9 and OSC 777 escape sequences, which a program uses to send a message of its own. That second one is how coding agents say they are waiting on your input. Either way the terminal's row gets a 🔔 in the sidebar, and a banner is posted unless you are already looking at that terminal.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A Focus mode can hold banners back even when this says Allowed. Add Wietty to the Focus's allowed apps if you want them through.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Desktop notifications from programs") {
            Toggle("Let programs post notifications (OSC 9 and OSC 777)",
                   isOn: Binding(get: { desktopNotifications.isEnabled },
                                 set: { desktopNotifications.setEnabled($0) }))
            if desktopNotifications.overridesUserConfig {
                Label("Your own Ghostty config sets this to \(desktopNotifications.userConfigValue ? "on" : "off"). Wietty is overriding it.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = desktopNotifications.writeFailure {
                Label("Could not save that: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("Turned off, a program asking for a notification is answered by nothing: no banner, no 🔔, and no error either. It is libghostty that enforces this, before any of the settings above are consulted, so it is the first thing to check when notifications are not arriving.")
                .font(.caption).foregroundStyle(.secondary)
            Text("This writes desktop-notifications to \(desktopNotifications.fileURL.path), which Wietty loads after your own Ghostty config so what is set here wins. Ghostty.app is not affected either way. Until you touch it your Ghostty config decides, and deleting that file goes back to that.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Test notification") {
            HStack {
                Button("Send test notification") {
                    Task {
                        testResult = await bells.sendTest(sound: store.bellSound)
                        // The test is also the one moment permission is decided, if
                        // it had not been asked for yet.
                        permission = await bells.permission()
                    }
                }
                Spacer()
            }
            switch testResult {
            case .posted:
                Text("Posted. If no banner appeared, a Focus mode or Notification Centre is holding it back.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Label("Not posted: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            case nil:
                Text("Posts one notification, so the whole path can be checked without waiting for a terminal to ring. It reports what happened either way: macOS refuses to ask on behalf of an app bundle that is not properly signed, without showing anyone a prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Bell sound") {
            HStack {
                Picker("Sound", selection: $store.bellSound) {
                    ForEach(soundChoices) { sound in
                        Text(sound.title).tag(sound)
                    }
                }
                Button("Test") { soundPreviewFailed = !store.bellSound.play() }
                    .disabled(store.bellSound == .silent)
            }
            if soundPreviewFailed {
                Label("That sound could not be loaded. macOS may no longer install it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Text("Played by every notification a terminal posts. \"Default\" is the alert sound chosen in System Settings › Sound. \"Test\" plays it here; \"Send test notification\" above is what checks that a banner carries it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // A new selection has not failed yet, so the warning about the old one goes.
        .onChange(of: store.bellSound) { soundPreviewFailed = false }
        // Read on the way in rather than once per app launch: permission can be
        // granted or revoked in System Settings while Wietty runs, and this tab is
        // the one place that would then be wrong about it.
        // Both are read on the way in rather than once per launch, and for the same
        // reason: each can be changed outside this app while it runs. Permission in
        // System Settings, and `desktop-notifications` in either config file.
        .task {
            permission = await bells.permission()
            desktopNotifications.refresh()
        }
    }

    /// The installed sounds, plus whatever is stored if it is not among them. A
    /// macOS update that removes a sound would otherwise leave the picker showing an
    /// empty selection, which reads as a broken control rather than as a sound that
    /// is no longer there.
    private var soundChoices: [BellSound] {
        let offered = BellSound.offered
        return offered.contains(store.bellSound) ? offered : offered + [store.bellSound]
    }

    private var permissionTitle: String {
        switch permission {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notAsked: return "Not asked yet"
        case nil: return "Checking…"
        }
    }

    private var permissionIcon: String {
        switch permission {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notAsked, nil: return "questionmark.circle"
        }
    }

    private var permissionColour: Color {
        switch permission {
        case .granted: return .green
        case .denied: return .red
        case .notAsked, nil: return .secondary
        }
    }
}

/// A settings row whose field is only a few characters wide: a port, and nothing
/// else so far.
///
/// A row of its own rather than a `.frame(width:)` on the field, because that is not
/// the same thing. A grouped form lays a field out as its label on the left and the
/// field on the right, and it gives up that layout for a field with a width of its
/// own: the label moves to a line above and the narrow field sits under it, left
/// aligned, out of line with every other field in the section. This keeps the row and
/// narrows only what is inside it.
///
/// Shared by `SettingsView` and `RemoteConnectionRow`, which is why it is a type at
/// file scope rather than a method on either.
private struct NarrowFieldRow<Field: View>: View {
    /// How wide a field this narrow is. One number, so the four of them cannot drift
    /// apart by a few points each.
    static var width: Double { 80 }

    let label: String
    @ViewBuilder let field: () -> Field

    init(_ label: String, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.field = field
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            field()
                .labelsHidden()
                .frame(width: Self.width)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// One colour row: a label, an optional reset button, and a colour well.
///
/// The colour is optional and nil means "no override": the well then previews the
/// default handed in, and the reset button is hidden because there is nothing to
/// reset. Picking a colour sets it; the reset button clears it back to nil. The well
/// is `labelsHidden` with the label drawn separately so the reset button can sit
/// between them rather than after the well, where a grouped form would push it.
///
/// Shared by both colour sections (Wietty's own colours and the terminal's), which
/// is why it takes a plain `Binding<Color?>`: the app colours bind straight into the
/// store, while the terminal colours bind through `GhosttyColorSettings` so a write
/// reloads the live config.
private struct ColorSettingRow: View {
    let title: String
    let defaultColor: Color
    @Binding var color: Color?

    init(_ title: String, default defaultColor: Color, color: Binding<Color?>) {
        self.title = title
        self.defaultColor = defaultColor
        _color = color
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if color != nil {
                Button { color = nil } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            }
            ColorPicker("", selection: Binding(get: { color ?? defaultColor },
                                               set: { color = $0 }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }
}

/// One row in the "Groups" section: the group's name with edit and delete buttons,
/// or (while editing) an inline field to rename it. The single-field sibling of
/// `AgentRow`.
struct GroupRow: View {
    let group: WorkspaceGroup
    let onUpdate: (WorkspaceGroup) -> Void
    let onDelete: () -> Void

    @State private var isEditing: Bool
    @State private var name: String

    init(group: WorkspaceGroup, isEditing: Bool = false,
         onUpdate: @escaping (WorkspaceGroup) -> Void, onDelete: @escaping () -> Void) {
        self.group = group
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _isEditing = State(initialValue: isEditing)
        _name = State(initialValue: group.name)
    }

    var body: some View {
        if isEditing {
            HStack {
                TextField("Name", text: $name)
                Button("Cancel") { cancelEditing() }
                Button("Save") { save() }.disabled(!edited.isValid)
            }
        } else {
            HStack {
                Text(group.displayName)
                Spacer()
                Button(action: { isEditing = true }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit group")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove group")
            }
        }
    }

    /// The group the field describes, keeping the id: a rename replaces the entry it
    /// started from rather than adding a second one, and keeps every workspace filed
    /// under it.
    private var edited: WorkspaceGroup { WorkspaceGroup(id: group.id, name: name) }

    private func cancelEditing() {
        name = group.name
        isEditing = false
    }

    private func save() {
        guard edited.isValid else { return }
        onUpdate(edited)
        isEditing = false
    }
}

/// One row in the "Agents" section: a summary line with edit and delete buttons,
/// or (while editing) an inline form for name, command and default arguments.
///
/// Internal rather than private, and its `init` takes the editing state, for the
/// same reason `NotificationSettings.init` takes a permission: the editing half is
/// never on screen on the way into the tab, so a render of the tab alone would cover
/// the reading half and look like it covered both.
struct AgentRow: View {
    let agent: AgentDefinition
    let onUpdate: (AgentDefinition) -> Void
    let onDelete: () -> Void

    @State private var isEditing: Bool
    @State private var name: String
    @State private var command: String
    @State private var arguments: String

    init(agent: AgentDefinition, isEditing: Bool = false,
         onUpdate: @escaping (AgentDefinition) -> Void, onDelete: @escaping () -> Void) {
        self.agent = agent
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _isEditing = State(initialValue: isEditing)
        _name = State(initialValue: agent.name)
        _command = State(initialValue: agent.command)
        _arguments = State(initialValue: agent.defaultArguments)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                TextField("Default Arguments", text: $arguments)
                HStack {
                    Button("Cancel") { cancelEditing() }
                    Spacer()
                    Button("Save") { save() }.disabled(!edited.isValid)
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.displayName)
                    // What starting it types, rather than the command and the
                    // arguments as two facts: the line is what actually runs.
                    Text(agent.launchCommand())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { isEditing = true }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit agent")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove agent")
            }
        }
    }

    /// The agent the fields currently describe, keeping the id: an edit replaces the
    /// entry it started from rather than adding a second one.
    private var edited: AgentDefinition {
        AgentDefinition(id: agent.id, name: name, command: command, defaultArguments: arguments)
    }

    private func cancelEditing() {
        name = agent.name
        command = agent.command
        arguments = agent.defaultArguments
        isEditing = false
    }

    private func save() {
        guard edited.isValid else { return }
        onUpdate(edited)
        isEditing = false
    }
}

/// One row in the "Remote connections" section: a summary line with edit and
/// delete buttons, or (while editing) an inline form for name/host/port/token.
private struct RemoteConnectionRow: View {
    let connection: RemoteConnection
    let onUpdate: (RemoteConnection) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var token: String

    init(connection: RemoteConnection, onUpdate: @escaping (RemoteConnection) -> Void, onDelete: @escaping () -> Void) {
        self.connection = connection
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: String(connection.port))
        _token = State(initialValue: connection.token)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                NarrowFieldRow("Port") { TextField("Port", text: $port) }
                SecureField("Token", text: $token)
                HStack {
                    Button("Cancel") { cancelEditing() }
                    Spacer()
                    Button("Save") { save() }.disabled(!isValid)
                }
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name)
                    Text("\(connection.host):\(connection.port)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { isEditing = true }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit connection")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove connection")
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
    }

    private func cancelEditing() {
        name = connection.name
        host = connection.host
        port = String(connection.port)
        token = connection.token
        isEditing = false
    }

    private func save() {
        guard let portValue = Int(port) else { return }
        onUpdate(RemoteConnection(
            id: connection.id,
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            token: token
        ))
        isEditing = false
    }
}
