import SwiftUI
import WiettyShared

struct SettingsView: View {
    @Bindable var store: ProjectStore
    @ObservedObject var remoteConnections: RemoteConnectionsStore
    @ObservedObject var remoteWorkspaces: RemoteWorkspacesController
    /// The app's own notifier, not one built here: the permission the Notifications
    /// tab reports has to be the permission the bells are subject to.
    let bells: BellNotifier

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

    /// - Parameter tab: which tab is up. Defaults to the one the panel opens on;
    ///   only the tests pass anything else, because only one tab's subtree is built
    ///   at a time and a render test that could not choose would cover one fifth of
    ///   the panel while looking like it covered all of it.
    init(store: ProjectStore,
         remoteConnections: RemoteConnectionsStore,
         remoteWorkspaces: RemoteWorkspacesController,
         bells: BellNotifier,
         tab: SettingsTab = .default) {
        _store = Bindable(wrappedValue: store)
        _remoteConnections = ObservedObject(wrappedValue: remoteConnections)
        _remoteWorkspaces = ObservedObject(wrappedValue: remoteWorkspaces)
        self.bells = bells
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
                periodicChecksSection
            }
        case .notifications:
            form { NotificationSettings(store: store, bells: bells) }
        case .agents:
            placeholder
        case .remote:
            form {
                remoteAccessSection
                remoteConnectionsSection
            }
        case .mcp:
            form { mcpSection }
        }
    }

    /// The one grouped form every tab with settings in it draws, so the three of
    /// them cannot drift in style or in how they fill the pane.
    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var placeholder: some View {
        if let placeholder = tab.placeholder {
            ContentUnavailableView(placeholder.title,
                                   systemImage: placeholder.systemImage,
                                   description: Text(placeholder.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var mcpSection: some View {
        Section {
            portField("MCP server", value: $store.mcpPort)
            if let error = store.mcpStartupError {
                Label("MCP server did not start: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("The loopback TCP port the MCP server listens on. It restarts on the new port as soon as you change it. See documentation/mcp.md.")
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
                TextField("Port", text: $newPort)
                    .frame(width: 80)
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
            Text("Seconds between checks for each tier. Which check runs at which tier depends on context (collapsed vs expanded workspace, pending CI, attention). See documentation/periodic-checks.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var newConnectionIsValid: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !newHost.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(newPort) != nil
            && !newToken.isEmpty
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
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
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

    /// Nil until the first read comes back, which is a state worth drawing: "not
    /// asked yet" and "we have not looked yet" are different things to say.
    @State private var permission: NotificationPermission?
    @State private var testResult: BellNotifier.TestResult?

    /// - Parameters:
    ///   - permission: what the tab starts out believing, and
    ///   - testResult: what it starts out reporting. Both default to the real state,
    ///     which is "nothing known yet" until the `task` below answers; only the
    ///     tests pass anything else, because these two decide four of the branches
    ///     drawn here and a render test that could not set them would cover one.
    init(store: ProjectStore, bells: BellNotifier,
         permission: NotificationPermission? = nil,
         testResult: BellNotifier.TestResult? = nil) {
        _store = Bindable(wrappedValue: store)
        self.bells = bells
        _permission = State(initialValue: permission)
        _testResult = State(initialValue: testResult)
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
                    Task { permission = await bells.requestPermission() }
                }
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
                Text("Posts one notification, so the whole path can be checked without waiting for a terminal to ring. It reports what happened either way: macOS refuses an app bundle run from a scratch directory outright.")
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
                Button("Test") { store.bellSound.play() }
                    .disabled(store.bellSound == .silent)
            }
            Text("Played by every notification a terminal posts. \"Default\" is the alert sound chosen in System Settings › Sound.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // Read on the way in rather than once per app launch: permission can be
        // granted or revoked in System Settings while Wietty runs, and this tab is
        // the one place that would then be wrong about it.
        .task { permission = await bells.permission() }
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
                TextField("Port", text: $port)
                    .frame(width: 80)
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
