import SwiftUI

/// One workspace's own page, reached from "Edit workspace…" in its card's menu and
/// drawn in the pane beside the sidebar, the way the app's settings are.
///
/// It holds two kinds of setting. The workspace's **group** is machine-local (like
/// its in-app name) and saved to `~/.config/wietty/config`, so it is here regardless
/// of anything on disk. The rest of the page edits the workspace's `wietty.json`:
/// its shell-init prelude, agents, terminals, processes and tests. Those need a
/// `wietty.json` to write to, which only exists once config sync is on, so when sync
/// is off the page offers to turn it on rather than showing empty editors.
///
/// Every edit routes through a `store` mutator that rebuilds the file from the
/// workspace's live state and agrees to the lines it now runs: typing a command
/// here is the consent the config-approval prompt would otherwise ask for.
struct WorkspaceSettingsView: View {
    static let groupSectionTitle = "Group"
    /// Shown for "no group": the workspace is in none, and so appears only under "All".
    static let noGroupTitle = "None"
    static let systemImage = "slider.horizontal.3"
    static let shellInitSectionTitle = "Shell init"
    static let agentsSectionTitle = "Agents"
    static let terminalsSectionTitle = "Terminals"
    static let processesSectionTitle = "Processes"
    static let testsSectionTitle = "Tests"
    /// The button shown when sync is off, and the same wording as the card menu's
    /// item so the two read as the one action.
    static let enableSyncTitle = "Enable config sync"

    /// The store the page reads from and writes back to. The page reflects a group
    /// added in Settings, or a row opened elsewhere, without being rebuilt.
    let store: ProjectStore

    /// The workspace this page is about, or nil when it has been removed while the
    /// page was up. `PaneRouter.workspacesChanged` takes the page off the screen a
    /// moment later; this covers the frame in between, the way the pane's "Connection
    /// removed" placeholder does.
    let project: Project?

    /// Bumped after turning sync on so the body re-reads `isSyncEnabled`, which asks
    /// the filesystem rather than an observed property and so does not re-render on
    /// its own.
    @State private var revision = 0

    var body: some View {
        if let project {
            Form {
                let _ = revision
                Section(Self.groupSectionTitle) { groupPicker(for: project) }
                if store.isSyncEnabled(project) {
                    configSections(for: project)
                } else {
                    syncDisabledSection(for: project)
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Workspace removed", systemImage: "folder.badge.minus")
        }
    }

    // MARK: Group (machine-local)

    @ViewBuilder private func groupPicker(for project: Project) -> some View {
        Picker(Self.groupSectionTitle, selection: groupBinding(for: project)) {
            Text(Self.noGroupTitle).tag(UUID?.none)
            ForEach(store.groups) { group in
                Text(group.displayName).tag(UUID?.some(group.id))
            }
        }
        .labelsHidden()
        if store.groups.isEmpty {
            caption("No groups yet. Add one in Settings › General, then it appears "
                    + "here to assign this workspace to.")
        } else {
            caption("Pick the group this workspace belongs to. Choose it in the app "
                    + "menu's Group submenu to show only its workspaces.")
        }
    }

    /// Reads the assignment from the live stored copy, not the passed-in `project`,
    /// which may predate an assignment made moments ago; writes it back through the
    /// store so it persists.
    private func groupBinding(for project: Project) -> Binding<UUID?> {
        Binding(
            get: { store.projects.first { $0.id == project.id }?.groupId },
            set: { store.assignGroup(project, to: $0) }
        )
    }

    // MARK: Sync off

    @ViewBuilder private func syncDisabledSection(for project: Project) -> some View {
        Section("Config file") {
            caption("This workspace has no wietty.json yet, so there is nothing to edit "
                    + "below. Turn config sync on to write one from the workspace's "
                    + "current terminals and agents; then its shell init, agents, "
                    + "terminals, processes and tests can be edited here.")
            Button(Self.enableSyncTitle) {
                store.enableConfigSync(for: project)
                revision += 1
            }
        }
    }

    // MARK: wietty.json sections

    /// Reads the live stored workspace so edits made through the store show at once;
    /// falls back to the passed-in copy for the frame before the store catches up.
    private func live(_ project: Project) -> Project {
        store.projects.first { $0.id == project.id } ?? project
    }

    @ViewBuilder private func configSections(for project: Project) -> some View {
        let current = live(project)
        let id = current.id
        let agents = current.terminals.filter { $0.kind == .claude }
        let terminals = current.terminals.filter { $0.kind == .terminal }
        let processNames = (current.configProcesses ?? [:]).keys.sorted()
        let testNames = (current.configTests ?? [:]).keys.sorted()

        Section(Self.shellInitSectionTitle) {
            ShellInitEditor(lines: current.configShellInit ?? []) { store.setShellInit($0, for: id) }
            caption("Shell lines run before every process and test command, in the same "
                    + "shell as the command. One line each. Use it for setup the "
                    + "environment map cannot express, such as sourcing a script.")
        }

        ListSettingsSection(title: Self.agentsSectionTitle, isEmpty: agents.isEmpty) {
            ReorderableForEach(items: agents,
                               onMove: { store.moveConfigRows(kind: .claude, fromOffsets: $0,
                                                              toOffset: $1, for: id) }) { ref in
                AgentConfigRow(ref: ref,
                               onSave: { store.updateConfigRow(ref.id, slot: $0, type: $1, prefix: $2,
                                                               fixedNaming: $3, for: id) },
                               onDelete: { store.removeTerminal(ref, in: current) })
            }
        } addForm: { collapse in
            AddAgentForm(onAdd: { store.addAgentRow(slot: $0, type: $1, prefix: $2, fixedNaming: $3, for: id) },
                         onAdded: collapse)
        } footer: {
            caption("Agent rows to lay out, in order. Type is the line the row runs "
                    + "(claude by default). A row that is open keeps the line it started "
                    + "with; close it to change what it runs.")
        }

        ListSettingsSection(title: Self.terminalsSectionTitle, isEmpty: terminals.isEmpty) {
            ReorderableForEach(items: terminals,
                               onMove: { store.moveConfigRows(kind: .terminal, fromOffsets: $0,
                                                              toOffset: $1, for: id) }) { ref in
                TerminalConfigRow(ref: ref,
                                  onSave: { store.updateConfigRow(ref.id, slot: $0, type: "", prefix: "",
                                                                  fixedNaming: false, for: id) },
                                  onDelete: { store.removeTerminal(ref, in: current) })
            }
        } addForm: { collapse in
            AddTerminalForm(onAdd: { store.addTerminalRow(slot: $0, for: id) }, onAdded: collapse)
        } footer: {
            caption("Terminal rows to open, in order. Each is just a label.")
        }

        ListSettingsSection(title: Self.processesSectionTitle, isEmpty: processNames.isEmpty) {
            ForEach(processNames, id: \.self) { name in
                ProcessConfigRow(name: name, config: current.configProcesses?[name] ?? ProcessConfig(command: ""),
                                 onSave: { store.updateProcess(originalName: $0, name: $1, config: $2, for: id) },
                                 onDelete: { store.removeProcess(name: name, for: id) })
            }
        } addForm: { collapse in
            AddProcessForm(onAdd: { store.addProcess(name: $0, config: $1, for: id) }, onAdded: collapse)
        } footer: {
            caption("Supervised processes, run by the app in the workspace folder. "
                    + "A long-running process is watched in the foreground; a daemon "
                    + "starts and detaches; a short-running one runs once.")
        }

        ListSettingsSection(title: Self.testsSectionTitle, isEmpty: testNames.isEmpty) {
            ForEach(testNames, id: \.self) { name in
                TestConfigRow(name: name, config: current.configTests?[name] ?? TestConfig(command: ""),
                              onSave: { store.updateTest(originalName: $0, name: $1, config: $2, for: id) },
                              onDelete: { store.removeTest(name: name, for: id) })
            }
        } addForm: { collapse in
            AddTestForm(onAdd: { store.addTest(name: $0, config: $1, for: id) }, onAdded: collapse)
        } footer: {
            caption("Run-to-completion checks. Exit code 0 passes, anything else fails. "
                    + "They show as the row of buttons on the workspace card.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Shared field editor

/// A bordered multi-line editor, the sibling of Settings' `PromptBodyEditor`: the
/// grouped form's `.roundedBorder` field style reaches `TextField` but not
/// `TextEditor`, which would otherwise draw as borderless text with no sign it can
/// be typed into.
struct ConfigTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 60

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: minHeight)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Shell init

/// The workspace-wide `shell_init`, edited as a block of lines. A draft that only
/// commits on Save, rather than rewriting the file on every keystroke; the Save and
/// Revert buttons appear once the draft differs from what is stored.
struct ShellInitEditor: View {
    let lines: [String]
    let onSave: ([String]) -> Void

    @State private var draft: String

    init(lines: [String], onSave: @escaping ([String]) -> Void) {
        self.lines = lines
        self.onSave = onSave
        _draft = State(initialValue: ConfigFieldText.fromLines(lines))
    }

    private var dirty: Bool { ConfigFieldText.toLines(draft) != lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConfigTextEditor(text: $draft)
            if dirty {
                HStack {
                    Button("Revert") { draft = ConfigFieldText.fromLines(lines) }
                    Spacer()
                    Button("Save") { onSave(ConfigFieldText.toLines(draft)) }
                }
            }
        }
    }
}

// MARK: - Agent rows

/// One agent row: a summary with edit and delete buttons, or an inline form for its
/// slot, the line it runs, a name prefix and the fixed-naming flag. `init` takes the
/// editing state so a render of the section covers the editing half too, the same
/// reason `AgentRow`'s does.
struct AgentConfigRow: View {
    let ref: TerminalRef
    /// slot, type, prefix, fixedNaming -> accepted. False keeps the row editing so a
    /// slot collision does not silently drop the edit.
    let onSave: (String, String, String, Bool) -> Bool
    let onDelete: () -> Void

    @State private var isEditing: Bool
    @State private var slot: String
    @State private var type: String
    @State private var prefix: String
    @State private var fixedNaming: Bool
    @State private var rejected = false

    init(ref: TerminalRef, isEditing: Bool = false,
         onSave: @escaping (String, String, String, Bool) -> Bool, onDelete: @escaping () -> Void) {
        self.ref = ref
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isEditing)
        _slot = State(initialValue: ref.slot)
        _type = State(initialValue: ref.command ?? ConfigReconcile.defaultAgentType)
        _prefix = State(initialValue: ref.prefix)
        _fixedNaming = State(initialValue: ref.fixedNaming)
    }

    private var hasSession: Bool { !ref.sessionId.isEmpty }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Slot", text: $slot)
                TextField("Type (the line it runs)", text: $type)
                    .disabled(hasSession)
                if hasSession {
                    Text("This row is open, so it keeps the line it started with. "
                         + "Close it to change the type.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Prefix", text: $prefix)
                Toggle("Fixed naming", isOn: $fixedNaming)
                if rejected {
                    Label("Another agent row already uses that slot.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { cancel() }
                    Spacer()
                    Button("Save") { save() }.disabled(slot.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .settingsFormBox()
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.displayName)
                    Text(ref.command ?? ConfigReconcile.defaultAgentType)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { isEditing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit agent row")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove agent row")
            }
        }
    }

    private func cancel() {
        slot = ref.slot
        type = ref.command ?? ConfigReconcile.defaultAgentType
        prefix = ref.prefix
        fixedNaming = ref.fixedNaming
        rejected = false
        isEditing = false
    }

    private func save() {
        if onSave(slot, type, prefix, fixedNaming) {
            rejected = false
            isEditing = false
        } else {
            rejected = true
        }
    }
}

/// The add form under the agent list: slot, type, prefix and the fixed-naming flag.
/// Its own state, cleared on a successful add.
struct AddAgentForm: View {
    let onAdd: (String, String, String, Bool) -> Bool
    var onAdded: () -> Void = {}

    @State private var slot = ""
    @State private var type = ConfigReconcile.defaultAgentType
    @State private var prefix = ""
    @State private var fixedNaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Slot", text: $slot)
            TextField("Type (the line it runs)", text: $type)
            TextField("Prefix", text: $prefix)
            Toggle("Fixed naming", isOn: $fixedNaming)
            HStack {
                Spacer()
                Button("Add agent row") {
                    if onAdd(slot, type.isEmpty ? ConfigReconcile.defaultAgentType : type, prefix, fixedNaming) {
                        slot = ""; type = ConfigReconcile.defaultAgentType; prefix = ""; fixedNaming = false
                        onAdded()
                    }
                }
                .disabled(slot.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Terminal rows

/// One terminal row: just a label. A summary with edit and delete, or an inline
/// field for the label.
struct TerminalConfigRow: View {
    let ref: TerminalRef
    let onSave: (String) -> Bool
    let onDelete: () -> Void

    @State private var isEditing: Bool
    @State private var slot: String
    @State private var rejected = false

    init(ref: TerminalRef, isEditing: Bool = false,
         onSave: @escaping (String) -> Bool, onDelete: @escaping () -> Void) {
        self.ref = ref
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isEditing)
        _slot = State(initialValue: ref.slot)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Label", text: $slot)
                if rejected {
                    Label("Another terminal row already uses that label.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { cancel() }
                    Spacer()
                    Button("Save") { save() }.disabled(slot.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .settingsFormBox()
        } else {
            HStack {
                Text(ref.slot)
                Spacer()
                Button { isEditing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Rename terminal row")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove terminal row")
            }
        }
    }

    private func cancel() { slot = ref.slot; rejected = false; isEditing = false }

    private func save() {
        if onSave(slot) { rejected = false; isEditing = false } else { rejected = true }
    }
}

/// The add form under the terminal list: one label field.
struct AddTerminalForm: View {
    let onAdd: (String) -> Bool
    var onAdded: () -> Void = {}
    @State private var slot = ""

    var body: some View {
        HStack {
            TextField("Label", text: $slot)
            Button("Add terminal row") { if onAdd(slot) { slot = ""; onAdded() } }
                .disabled(slot.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Process rows

/// One process row: a summary with edit and delete buttons, or an inline form for
/// every field a process definition carries. Arrays (`shell_init`,
/// `restart_when_changed`) and the `env` map are edited as text, one entry per line.
struct ProcessConfigRow: View {
    let name: String
    let config: ProcessConfig
    /// originalName, name, config -> accepted. False keeps the row editing on a name
    /// collision.
    let onSave: (String, String, ProcessConfig) -> Bool
    let onDelete: () -> Void

    @State private var isEditing: Bool
    @State private var draftName: String
    @State private var command: String
    @State private var kind: ProcessKind
    @State private var stop: String
    @State private var status: String
    @State private var autoStart: Bool
    @State private var autoRestart: Bool
    @State private var allowEmptyVars: Bool
    @State private var envText: String
    @State private var restartText: String
    @State private var shellInitText: String
    @State private var rejected = false

    init(name: String, config: ProcessConfig, isEditing: Bool = false,
         onSave: @escaping (String, String, ProcessConfig) -> Bool, onDelete: @escaping () -> Void) {
        self.name = name
        self.config = config
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isEditing)
        _draftName = State(initialValue: name)
        _command = State(initialValue: config.command)
        _kind = State(initialValue: config.kind)
        _stop = State(initialValue: config.stop ?? "")
        _status = State(initialValue: config.status ?? "")
        _autoStart = State(initialValue: config.autoStart)
        _autoRestart = State(initialValue: config.autoRestart)
        _allowEmptyVars = State(initialValue: config.allowEmptyVars)
        _envText = State(initialValue: ConfigFieldText.fromEnv(config.env))
        _restartText = State(initialValue: ConfigFieldText.fromLines(config.restartWhenChanged))
        _shellInitText = State(initialValue: ConfigFieldText.fromLines(config.shellInit))
    }

    private var valid: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var edited: ProcessConfig {
        ProcessConfig(
            command: command,
            kind: kind,
            stop: stop.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stop,
            status: status.trimmingCharacters(in: .whitespaces).isEmpty ? nil : status,
            autoStart: autoStart,
            autoRestart: autoRestart,
            restartWhenChanged: ConfigFieldText.toLines(restartText),
            env: ConfigFieldText.toEnv(envText),
            allowEmptyVars: allowEmptyVars,
            shellInit: ConfigFieldText.toLines(shellInitText)
        )
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $draftName)
                TextField("Command", text: $command)
                Picker("Kind", selection: $kind) {
                    Text("long_running").tag(ProcessKind.longRunning)
                    Text("daemon").tag(ProcessKind.daemon)
                    Text("short_running").tag(ProcessKind.shortRunning)
                }
                TextField("Stop command (optional)", text: $stop)
                TextField("Status probe (daemon, optional)", text: $status)
                Toggle("Auto start", isOn: $autoStart)
                Toggle("Auto restart", isOn: $autoRestart)
                Toggle("Allow empty variables", isOn: $allowEmptyVars)
                fieldLabel("Environment (KEY=VALUE per line)")
                ConfigTextEditor(text: $envText)
                fieldLabel("Restart when changed (path per line)")
                ConfigTextEditor(text: $restartText)
                fieldLabel("Shell init (line per entry)")
                ConfigTextEditor(text: $shellInitText)
                if rejected {
                    Label("Another process already uses that name.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { cancel() }
                    Spacer()
                    Button("Save") { save() }.disabled(!valid)
                }
            }
            .settingsFormBox()
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(config.command).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(config.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                Button { isEditing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit process")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove process")
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func cancel() {
        draftName = name
        command = config.command
        kind = config.kind
        stop = config.stop ?? ""
        status = config.status ?? ""
        autoStart = config.autoStart
        autoRestart = config.autoRestart
        allowEmptyVars = config.allowEmptyVars
        envText = ConfigFieldText.fromEnv(config.env)
        restartText = ConfigFieldText.fromLines(config.restartWhenChanged)
        shellInitText = ConfigFieldText.fromLines(config.shellInit)
        rejected = false
        isEditing = false
    }

    private func save() {
        guard valid else { return }
        if onSave(name, draftName, edited) { rejected = false; isEditing = false } else { rejected = true }
    }
}

/// The add form under the process list: name, command, and the kind. The rest of a
/// process's fields are left at their defaults and refined by editing the row, so
/// the add form stays short.
struct AddProcessForm: View {
    let onAdd: (String, ProcessConfig) -> Bool
    var onAdded: () -> Void = {}

    @State private var name = ""
    @State private var command = ""
    @State private var kind = ProcessKind.longRunning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name)
            TextField("Command", text: $command)
            Picker("Kind", selection: $kind) {
                Text("long_running").tag(ProcessKind.longRunning)
                Text("daemon").tag(ProcessKind.daemon)
                Text("short_running").tag(ProcessKind.shortRunning)
            }
            HStack {
                Spacer()
                Button("Add process") {
                    if onAdd(name, ProcessConfig(command: command, kind: kind)) {
                        name = ""; command = ""; kind = .longRunning
                        onAdded()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Test rows

/// One test row: a summary with edit and delete buttons, or an inline form for the
/// command, the empty-variable flag, and the env and shell-init fields (as text).
struct TestConfigRow: View {
    let name: String
    let config: TestConfig
    let onSave: (String, String, TestConfig) -> Bool
    let onDelete: () -> Void

    @State private var isEditing: Bool
    @State private var draftName: String
    @State private var command: String
    @State private var allowEmptyVars: Bool
    @State private var envText: String
    @State private var shellInitText: String
    @State private var rejected = false

    init(name: String, config: TestConfig, isEditing: Bool = false,
         onSave: @escaping (String, String, TestConfig) -> Bool, onDelete: @escaping () -> Void) {
        self.name = name
        self.config = config
        self.onSave = onSave
        self.onDelete = onDelete
        _isEditing = State(initialValue: isEditing)
        _draftName = State(initialValue: name)
        _command = State(initialValue: config.command)
        _allowEmptyVars = State(initialValue: config.allowEmptyVars)
        _envText = State(initialValue: ConfigFieldText.fromEnv(config.env))
        _shellInitText = State(initialValue: ConfigFieldText.fromLines(config.shellInit))
    }

    private var valid: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var edited: TestConfig {
        TestConfig(command: command, env: ConfigFieldText.toEnv(envText),
                   allowEmptyVars: allowEmptyVars, shellInit: ConfigFieldText.toLines(shellInitText))
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $draftName)
                TextField("Command", text: $command)
                Toggle("Allow empty variables", isOn: $allowEmptyVars)
                fieldLabel("Environment (KEY=VALUE per line)")
                ConfigTextEditor(text: $envText)
                fieldLabel("Shell init (line per entry)")
                ConfigTextEditor(text: $shellInitText)
                if rejected {
                    Label("Another test already uses that name.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") { cancel() }
                    Spacer()
                    Button("Save") { save() }.disabled(!valid)
                }
            }
            .settingsFormBox()
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(config.command).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { isEditing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit test")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove test")
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func cancel() {
        draftName = name
        command = config.command
        allowEmptyVars = config.allowEmptyVars
        envText = ConfigFieldText.fromEnv(config.env)
        shellInitText = ConfigFieldText.fromLines(config.shellInit)
        rejected = false
        isEditing = false
    }

    private func save() {
        guard valid else { return }
        if onSave(name, draftName, edited) { rejected = false; isEditing = false } else { rejected = true }
    }
}

/// The add form under the test list: name and command.
struct AddTestForm: View {
    let onAdd: (String, TestConfig) -> Bool
    var onAdded: () -> Void = {}

    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $name)
            TextField("Command", text: $command)
            HStack {
                Spacer()
                Button("Add test") {
                    if onAdd(name, TestConfig(command: command)) { name = ""; command = ""; onAdded() }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
