import Foundation
import Observation

/// Whether the prompt-template popup is up. Owned by the app rather than by a view,
/// like `PaneRouter`, for the same reason: ⌘P and the "Prompt templates" app-menu item
/// are declared in the scene's `commands`, which cannot reach a view's `@State`, so the
/// flag they flip has to live above the window. `ContentView` presents the popup as a
/// sheet bound to it.
@MainActor
@Observable
final class PromptTemplatePresentation {
    var isPresented = false

    /// The two ways in (the menu item and ⌘P) both call this. Shows rather than
    /// toggles: ⌘P a second time while the popup is up is a keystroke into the search
    /// field, not a request to close it, and the sheet has its own Esc and Cancel.
    func show() {
        isPresented = true
    }
}
