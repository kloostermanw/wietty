import Foundation

/// The popup's search over the prompt templates. A pure type, like `WorkspaceGroupMenu`,
/// so which templates a query keeps is asserted in CI rather than only by typing.
///
/// A subsequence match, the way a command palette filters: the query characters have to
/// appear in order, but not adjacently, so "fb" finds "Fix bug". The name is searched
/// first and the description as a fallback, both case-insensitively. The input order is
/// preserved, because the store already hands templates sorted by name.
enum PromptTemplateFilter {
    static func match(_ templates: [PromptTemplate], query: String) -> [PromptTemplate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return templates }
        let needle = trimmed.lowercased()
        return templates.filter {
            isSubsequence(needle, of: $0.displayName.lowercased())
                || isSubsequence(needle, of: $0.summary.lowercased())
        }
    }

    /// Whether every character of `needle` appears in `haystack` in order.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
