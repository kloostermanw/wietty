import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// The popup renders in each of its states: the empty prompt, the list of templates,
/// and the argument step. Measured with `ImageRenderer` the way the settings panes
/// are, which needs neither a window nor a Metal device.
@MainActor
@Suite struct PromptTemplatePickerTests {
    private func store(_ templates: [(String, String)] = []) -> PromptTemplateStore {
        let store = PromptTemplateStore(file: .temporary())
        for (name, body) in templates {
            store.add(name: name, summary: "", argumentHint: "", body: body)
        }
        return store
    }

    private func renders<V: View>(_ view: V) -> Bool {
        ImageRenderer(content: view.frame(width: 460, height: 420)).nsImage != nil
    }

    @Test func theEmptyStateRenders() {
        let view = PromptTemplatePickerView(store: store(), onInject: { _ in }, onCancel: {})
        #expect(renders(view))
    }

    @Test func aListOfTemplatesRenders() {
        let view = PromptTemplatePickerView(store: store([("Fix bug", "Body."),
                                                          ("Refactor", "Body.")]),
                                            onInject: { _ in }, onCancel: {})
        #expect(renders(view))
    }

    @Test func theArgumentStepRenders() {
        let template = PromptTemplate(name: "Fix bug", summary: "", argumentHint: "<ticket> <area>",
                                      body: "Fix $1 in $2.", fileURL: URL(fileURLWithPath: "/t.md"))
        let view = PromptTemplatePickerView(store: store(), onInject: { _ in }, onCancel: {},
                                            showingArgumentsFor: template)
        #expect(renders(view))
    }

    /// Choosing a template with no placeholders injects it straight away, rendered with
    /// no arguments. The behaviour the popup is for, checked without driving AppKit.
    @Test func choosingAPlainTemplateRendersItsBody() {
        let template = PromptTemplate(name: "Greet", summary: "", argumentHint: "",
                                      body: "Say hello.", fileURL: URL(fileURLWithPath: "/g.md"))
        #expect(template.render(arguments: [:]) == "Say hello.")
        #expect(template.hasArguments == false)
    }
}
