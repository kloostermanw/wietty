import Foundation
import Observation

/// The prompt templates the settings page edits and the popup lists, kept in step
/// with the `.md` files in `~/.config/wietty/prompt_templates/`.
///
/// Owned by the app rather than by a view, the way `PaneRouter` is: the popup is
/// opened from the app menu and ⌘P, which are declared in the scene's `commands` and
/// cannot reach a view's `@State`, so the list they show has to live above the window.
///
/// Unlike `WorkspaceGroup` and `AgentDefinition`, which the `ProjectStore` flattens
/// into indexed keys in the one config file, each template is its own file. So this is
/// its own store over `PromptTemplateFile` rather than more properties on
/// `ProjectStore`: the persistence is a directory of files, not the flat config.
@MainActor
@Observable
final class PromptTemplateStore {
    /// `private(set)` so the list only changes through the methods below, which keep it
    /// and the files in step. Re-read from disk after every change rather than mutated
    /// in place, so the in-memory order matches what a relaunch would show.
    private(set) var templates: [PromptTemplate] = []

    /// The last write that failed, for the settings page to show. Nil clears on the
    /// next successful change. A template the user typed and could not save is worth a
    /// line, the way a failed colour write is on the Ghostty colours section.
    private(set) var lastError: String?

    /// The file layer. Not private so a test can point a second store at the same
    /// directory to prove a change reached disk.
    let file: PromptTemplateFile

    init(file: PromptTemplateFile = PromptTemplateFile()) {
        self.file = file
        reload()
    }

    /// Re-reads the directory. Called on the way into the popup and the settings page,
    /// so a file added or edited outside the app shows without a relaunch.
    func reload() {
        do {
            templates = try file.list()
        } catch {
            templates = []
            lastError = error.localizedDescription
        }
    }

    /// Creates a template from the settings add-form and writes it to a new file, named
    /// from a slug of the name so two of the same name do not collide.
    func add(name: String, summary: String, argumentHint: String, body: String) {
        let template = PromptTemplate(
            name: name, summary: summary, argumentHint: argumentHint, body: body,
            fileURL: file.availableURL(forName: name)
        )
        perform { try file.save(template) }
    }

    /// Saves an edited template back to its own file. Identity is `fileURL`, so this
    /// replaces the file it came from rather than adding a second.
    func update(_ template: PromptTemplate) {
        perform { try file.save(template) }
    }

    func remove(_ template: PromptTemplate) {
        perform { try file.delete(template) }
    }

    /// Runs a file change, then re-reads the directory so the list reflects it. A
    /// failure is recorded rather than thrown: these are SwiftUI button actions, and
    /// the settings page shows `lastError`.
    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            lastError = nil
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
