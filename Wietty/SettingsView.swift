import SwiftUI
import WiettyShared

struct SettingsView: View {
    @Bindable var store: ProjectStore
    @ObservedObject var remoteConnections: RemoteConnectionsStore
    @ObservedObject var remoteWorkspaces: RemoteWorkspacesController

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
         tab: SettingsTab = .default) {
        _store = Bindable(wrappedValue: store)
        _remoteConnections = ObservedObject(wrappedValue: remoteConnections)
        _remoteWorkspaces = ObservedObject(wrappedValue: remoteWorkspaces)
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
        case .notifications, .agents:
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
