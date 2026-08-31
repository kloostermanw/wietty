import Testing
import Foundation
import SwiftUI
@testable import Wietty

/// The freshness detail popover renders its actionable results without a wiring
/// crash, the same insurance `WorkspaceConfigEditorViewTests` gives the config rows.
@MainActor
@Suite struct FreshnessViewTests {
    private func render(_ view: some View) -> Bool {
        ImageRenderer(content: view.frame(width: 260, height: 200)).nsImage != nil
    }

    @Test func detailViewRendersActionableResults() {
        let results = [
            FreshnessResult(name: "composer", actionNeeded: true, message: "run composer install",
                            detail: "composer.lock changed"),
            FreshnessResult(name: "clean", actionNeeded: false, message: "clean"),
        ]
        #expect(render(FreshnessDetailView(results: results)))
    }

    @Test func detailViewRendersWithNoActionableResults() {
        #expect(render(FreshnessDetailView(results: [])))
    }
}
