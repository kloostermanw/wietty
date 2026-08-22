import Testing
import Foundation
@testable import Wietty

/// The popup's search: which templates a typed query keeps, and in what order. Pure,
/// so asserted here rather than only by typing into the popup.
@Suite struct PromptTemplateFilterTests {
    private func template(_ name: String, summary: String = "") -> PromptTemplate {
        PromptTemplate(name: name, summary: summary, argumentHint: "", body: "b",
                       fileURL: URL(fileURLWithPath: "/\(name).md"))
    }

    @Test func anEmptyQueryKeepsEveryTemplateInOrder() {
        let all = [template("Apple"), template("Banana")]
        #expect(PromptTemplateFilter.match(all, query: "").map(\.name) == ["Apple", "Banana"])
    }

    @Test func aSubsequenceOfTheNameMatches() {
        let all = [template("Fix bug"), template("Refactor")]
        #expect(PromptTemplateFilter.match(all, query: "fb").map(\.name) == ["Fix bug"])
    }

    @Test func matchingIsCaseInsensitive() {
        let all = [template("Fix Bug")]
        #expect(PromptTemplateFilter.match(all, query: "FIX").map(\.name) == ["Fix Bug"])
    }

    @Test func aNonMatchingQueryDropsTheTemplate() {
        let all = [template("Fix bug")]
        #expect(PromptTemplateFilter.match(all, query: "zzz").isEmpty)
    }

    @Test func theDescriptionIsSearchedToo() {
        let all = [template("T1", summary: "handles authentication")]
        #expect(PromptTemplateFilter.match(all, query: "auth").map(\.name) == ["T1"])
    }

    @Test func matchesKeepTheGivenOrder() {
        // The store hands templates in sorted order; the filter must not reorder them.
        let all = [template("Alpha"), template("Beta"), template("Gamma")]
        #expect(PromptTemplateFilter.match(all, query: "a").map(\.name) == ["Alpha", "Beta", "Gamma"])
    }
}
