import Foundation

/// One reusable prompt for an AI agent: a markdown file the popup can type into the
/// focused terminal. Conceptually the same as Claude's command feature, a folder of
/// markdown files with optional frontmatter and argument placeholders.
///
/// A value type carrying the parsed pieces and the file it came from, like
/// `AgentDefinition` carries its fields. Identity is the file rather than a UUID: the
/// `.md` on disk is the template, so a rename of the display name in the frontmatter
/// keeps the same file, and the store's add/update/remove act on `fileURL`.
///
/// Frontmatter is optional and tolerant on purpose, the way `AgentDefinition`'s
/// decoder is: these are hand-editable files in the user's `~/.config`, so a file with
/// no frontmatter, or an unterminated one, is still a readable prompt rather than an
/// error. The filename (minus `.md`) is the fallback name.
struct PromptTemplate: Identifiable, Equatable {
    var name: String
    /// The `description` frontmatter key. Named `summary` here to stay clear of the
    /// `description` a type conforming to `CustomStringConvertible` would carry.
    var summary: String
    /// The `argument-hint` frontmatter key: the space-separated tokens that label the
    /// argument fields the popup shows, one token per positional placeholder.
    var argumentHint: String
    var body: String
    var fileURL: URL

    var id: URL { fileURL }

    /// One value the popup asks for before typing the template in. `index` is the
    /// `$N` it fills; `label` is what the field is titled, from the argument hint when
    /// there is a token for it.
    struct ArgumentField: Equatable {
        let index: Int
        let label: String
    }

    /// Reads a file's contents into a template. `fileURL`'s last path component (minus
    /// the extension) is the fallback name.
    static func parse(contents: String, fileURL: URL) -> PromptTemplate {
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        let (frontmatter, body) = splitFrontmatter(contents)
        let name = frontmatter["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return PromptTemplate(
            name: name,
            summary: frontmatter["description"] ?? "",
            argumentHint: frontmatter["argument-hint"] ?? "",
            body: body,
            fileURL: fileURL
        )
    }

    /// The fields the popup collects before typing this template in. One per distinct
    /// `$N` in the body, in ascending order, each labelled by the matching argument-hint
    /// token or by its own `$N` when the hint has no token for it. A body that uses only
    /// `$ARGUMENTS` still needs somewhere to type, so it gets one field.
    var argumentFields: [ArgumentField] {
        let positional = Self.positionalIndices(in: body).sorted()
        // A body that names no `$N` but does use `$ARGUMENTS` gets one field standing
        // for the lot, so its label is the whole hint rather than the first token.
        guard !positional.isEmpty else {
            guard body.contains("$ARGUMENTS") else { return [] }
            return [ArgumentField(index: 1, label: argumentHint.isEmpty ? "$ARGUMENTS" : argumentHint)]
        }
        let hintTokens = argumentHint.split(separator: " ").map(String.init)
        return positional.map { index in
            let label = index <= hintTokens.count ? hintTokens[index - 1] : "$\(index)"
            return ArgumentField(index: index, label: label)
        }
    }

    /// Whether picking this template needs an argument step at all.
    var hasArguments: Bool { !argumentFields.isEmpty }

    /// The body with `$ARGUMENTS` and each `$N` replaced by the given values, keyed by
    /// placeholder index. Keyed rather than positional so a body whose placeholders do
    /// not start at `$1` or skip a number (`$2` alone, or `$1 $3`) keeps the value typed
    /// for each: a positional array conflates "the second field" with "$2" and drops the
    /// value when the two disagree.
    ///
    /// A `$N` with no value becomes empty rather than staying a literal `$N`: a
    /// half-filled prompt reads as a mistake, a stray `$2` reads as the tool being
    /// broken. `$ARGUMENTS` is the provided values in ascending index order, joined by a
    /// space, with no gap for an index the body never used.
    func render(arguments: [Int: String]) -> String {
        let all = arguments.keys.sorted().map { arguments[$0] ?? "" }.joined(separator: " ")
        let result = NSMutableString(string: body)
        let range = NSRange(location: 0, length: result.length)
        // One pass over the original body, applied back to front so each earlier match
        // keeps its range as the string changes length. Matching only the body, never
        // the growing result, is what actually stops re-substitution: a value that
        // itself contains `$1`, and the text `$ARGUMENTS` expands to, are written in
        // as-is and never scanned again. A single greedy match per placeholder also
        // means `$1` can never eat the `$1` inside `$10`.
        for match in Self.placeholder.matches(in: body, range: range).reversed() {
            let replacement: String
            if let r = Range(match.range(at: 1), in: body), let index = Int(body[r]) {
                replacement = arguments[index] ?? ""
            } else {
                replacement = all
            }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    /// The trimmed display name, for the same reason `AgentDefinition.displayName` is
    /// trimmed: it is typed into a text field.
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A template needs a name to label its row and its popup entry, so one without a
    /// name cannot be saved. The same gate `WorkspaceGroup.isValid` is.
    var isValid: Bool { !displayName.isEmpty }

    // MARK: Parsing helpers

    /// `$ARGUMENTS` or a 1-based `$N`. `$0` is deliberately not a placeholder: index 0
    /// has no argument field (the fields are 1-based), so a hand-edited body that writes
    /// `$0` keeps it literal rather than driving the argument step to a `-1` index and
    /// crashing. Compiled once from a constant pattern, so `try!` cannot fire, and shared
    /// by `render` and `positionalIndices` so both agree on what a placeholder is.
    private static let placeholder = try! NSRegularExpression(pattern: "\\$ARGUMENTS|\\$([1-9][0-9]*)")

    /// The distinct `$N` indices referenced in `text`. `$ARGUMENTS` matches have no
    /// capture group, so `Range(_:in:)` returns nil for them and they are skipped.
    private static func positionalIndices(in text: String) -> Set<Int> {
        let range = NSRange(text.startIndex..., in: text)
        var indices: Set<Int> = []
        for match in placeholder.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text), let n = Int(text[r]) {
                indices.insert(n)
            }
        }
        return indices
    }

    /// Splits leading `---` frontmatter from the body. A file that does not open with a
    /// `---` line, or whose frontmatter is never closed by another `---`, has no
    /// frontmatter: the whole file is the body, so nothing is silently dropped.
    private static func splitFrontmatter(_ contents: String) -> (fields: [String: String], body: String) {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], contents)
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return ([:], contents)
        }

        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        let body = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }
}
