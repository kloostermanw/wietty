import SwiftUI

/// A settings section whose body is a list of items: the section title on the left
/// with an Add button on the right, then the rows, then an add form that stays
/// hidden until it is needed.
///
/// The add form shows when the list is empty (there is nothing to do but add the
/// first item) or when Add is pressed, and hides again on a successful add or on
/// Cancel. This keeps a section with a dozen fields in its add form from pushing the
/// existing rows down a screenful when all the user wants is to read them. Used by
/// both the app Settings lists and the Edit workspace lists so the two behave alike.
struct ListSettingsSection<Rows: View, AddForm: View, Footer: View>: View {
    let title: String
    /// Whether the list has no items. When true the add form is shown with no way to
    /// collapse it, since there is nothing behind it to go back to.
    let isEmpty: Bool
    @ViewBuilder let rows: () -> Rows
    /// Builds the add form, handed a `collapse` closure to call after a successful
    /// add so the form folds away (unless the list is still empty).
    @ViewBuilder let addForm: (_ collapse: @escaping () -> Void) -> AddForm
    @ViewBuilder let footer: () -> Footer

    @State private var isAdding = false

    private var showingForm: Bool { isEmpty || isAdding }

    var body: some View {
        Section {
            rows()
            if showingForm {
                // Boxed, so the add form reads as a distinct thing to fill in rather
                // than another row in the list above it.
                addForm { isAdding = false }
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            }
            footer()
        } header: {
            HStack {
                Text(title)
                Spacer()
                // Nothing to reveal or hide while the form is already forced open by
                // an empty list, so the button only appears once there are rows.
                if !isEmpty {
                    Button(isAdding ? "Cancel" : "Add") { isAdding.toggle() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}
