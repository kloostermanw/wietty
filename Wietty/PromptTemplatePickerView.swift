import SwiftUI

/// The popup for picking a prompt template and typing it into the focused terminal.
/// Opened by ⌘P and the "Prompt templates" app-menu item, presented as a sheet.
///
/// Two steps. First a search field over the templates, filtered as you type, chosen
/// with Return or a double click. A template with `$1`/`$2`/`$ARGUMENTS` then asks for
/// those values, one field per placeholder; a template with none is typed in straight
/// away. Either way the rendered text goes to `onInject`, which the window turns into a
/// write to the focused terminal.
///
/// The view knows nothing about terminals: it hands back rendered text and lets the
/// window decide where it goes, so the "no terminal focused" case is the window's to
/// report, not this view's.
struct PromptTemplatePickerView: View {
    let store: PromptTemplateStore
    let onInject: (String) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    /// The highlighted template's file URL. Seeded to the first match and moved by the
    /// arrow keys, so Return has something to choose without a click.
    @State private var selection: PromptTemplate.ID?
    /// The template whose arguments are being collected, once one with placeholders is
    /// chosen. Nil while still choosing.
    @State private var argumentsFor: PromptTemplate?
    /// The value typed for each argument field, by placeholder index.
    @State private var argumentValues: [Int: String] = [:]
    @FocusState private var searchFocused: Bool

    /// - Parameter showingArgumentsFor: the template whose argument step to open on.
    ///   Defaults to nil, which starts on the search field; only the tests pass one,
    ///   because the two steps are never on screen at once and a render of the search
    ///   step alone would look like it covered both, the way `AgentRow` takes
    ///   `isEditing`.
    init(store: PromptTemplateStore,
         onInject: @escaping (String) -> Void,
         onCancel: @escaping () -> Void,
         showingArgumentsFor template: PromptTemplate? = nil) {
        self.store = store
        self.onInject = onInject
        self.onCancel = onCancel
        _argumentsFor = State(initialValue: template)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let template = argumentsFor {
                arguments(for: template)
            } else {
                choosing
            }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: Choosing

    private var filtered: [PromptTemplate] {
        PromptTemplateFilter.match(store.templates, query: query)
    }

    @ViewBuilder private var choosing: some View {
        TextField("Search prompt templates", text: $query)
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($searchFocused)
            .padding(12)
            .onSubmit { chooseHighlighted() }
            // Return and the arrow keys drive the list from the search field, which
            // keeps the focus, so typing never has to leave it to move the selection.
            .onMoveCommand { move($0) }
            .onChange(of: query) { keepSelectionInResults() }
            // The sheet opens ready to type, rather than needing a click into the field
            // first: the popup is a keyboard action (⌘P), so the keyboard should land in
            // it.
            .onAppear { searchFocused = true }
        Divider()
        if filtered.isEmpty {
            emptyState
        } else {
            List(filtered, selection: $selection) { template in
                row(template)
                    .tag(template.id)
                    .contentShape(Rectangle())
                    .onTapGesture { choose(template) }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ template: PromptTemplate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(template.displayName)
            if let caption = caption(for: template) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func caption(for template: PromptTemplate) -> String? {
        if !template.summary.isEmpty { return template.summary }
        if !template.argumentHint.isEmpty { return template.argumentHint }
        return nil
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 6) {
            if let error = store.lastError {
                // A load failure and a genuinely empty directory both leave `templates`
                // empty, so without this they would render alike and a user whose files
                // failed to read would be told to go create templates they already have.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Fix it in Settings › Prompts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if store.templates.isEmpty {
                Text("No prompt templates yet.")
                Text("Create one in Settings › Prompts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No matches.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Arguments

    @ViewBuilder private func arguments(for template: PromptTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(template.displayName).font(.title3)
            ForEach(template.argumentFields, id: \.index) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    TextField(field.label, text: binding(for: field.index))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Spacer()
            HStack {
                Button("Back") { argumentsFor = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Insert") { insert(template) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(get: { argumentValues[index] ?? "" },
                set: { argumentValues[index] = $0 })
    }

    // MARK: Choosing and rendering

    /// The template Return acts on: whatever is highlighted, or the first match when
    /// nothing is (an empty selection right after typing narrows the list).
    private func chooseHighlighted() {
        guard let template = filtered.first(where: { $0.id == selection }) ?? filtered.first
        else { return }
        choose(template)
    }

    private func choose(_ template: PromptTemplate) {
        if template.hasArguments {
            argumentValues = [:]
            argumentsFor = template
        } else {
            onInject(template.render(arguments: [:]))
        }
    }

    private func insert(_ template: PromptTemplate) {
        onInject(template.render(arguments: argumentValues))
    }

    /// Moves the highlight up or down the filtered list for the arrow keys.
    private func move(_ direction: MoveCommandDirection) {
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex { $0.id == selection } ?? -1
        let next: Int
        switch direction {
        case .up: next = max(0, current - 1)
        case .down: next = min(filtered.count - 1, current + 1)
        default: return
        }
        selection = filtered[next].id
    }

    /// Keeps the highlight on a row that is still in the results as the query narrows
    /// them, so Return never acts on a template that scrolled out of the list.
    private func keepSelectionInResults() {
        if !filtered.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
    }
}
