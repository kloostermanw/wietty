import Foundation

/// The `~/.config/wietty/prompt_templates/` directory: one markdown file per prompt
/// template. The file counterpart to `WiettyConfigFile`, but a directory of files
/// rather than one flat file, because a template body is multi-line and each template
/// is the user's to hand-edit on its own.
///
/// Listing is tolerant, the way `AgentDefinition`'s decoder is: a file with no
/// frontmatter, or a `.txt` a user dropped in, does not fail the whole list. Only
/// `.md` files are templates; a file with no frontmatter is a plain body named by its
/// filename.
struct PromptTemplateFile {
    let directory: URL

    /// `~/.config/wietty/prompt_templates`, beside `config` and `ghostty.cfg`.
    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/wietty/prompt_templates")
    }

    init(directory: URL = PromptTemplateFile.defaultURL) {
        self.directory = directory
    }

    /// Every readable template, sorted by display name so the list and the popup show
    /// a stable order rather than the file system's. An absent directory lists empty,
    /// the way an absent config file reads empty: it is the first launch, not an error.
    func list() throws -> [PromptTemplate] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> PromptTemplate? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return PromptTemplate.parse(contents: contents, fileURL: url)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Writes the template to its `fileURL`, creating the directory when absent. Saving
    /// a template that already has a file replaces it in place rather than adding a
    /// second, because `fileURL` is the identity.
    func save(_ template: PromptTemplate) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.serialize(template).write(to: template.fileURL, atomically: true, encoding: .utf8)
    }

    func delete(_ template: PromptTemplate) throws {
        try FileManager.default.removeItem(at: template.fileURL)
    }

    /// A file URL for a new template with the given name: the slug plus `.md`, with a
    /// numeric suffix when that name is already taken, so a second "Fix bug" does not
    /// overwrite the first.
    func availableURL(forName name: String) -> URL {
        let base = Self.slug(name)
        var candidate = directory.appendingPathComponent("\(base).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).md")
            suffix += 1
        }
        return candidate
    }

    /// A filename-safe slug of a display name: lowercased, runs of non-alphanumerics
    /// collapsed to single hyphens, ends trimmed. A name with nothing usable in it
    /// falls back to "template" so the file is still named.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let hyphenated = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        var slug = String(hyphenated)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "template" : slug
    }

    /// The file's text: frontmatter for the fields that carry a value, then the body.
    /// `name` is always written so the display name round-trips even when it matches
    /// the filename; `description` and `argument-hint` only when set, so a plain
    /// template stays plain.
    private static func serialize(_ template: PromptTemplate) -> String {
        var frontmatter = ["name: \(template.name)"]
        if !template.summary.isEmpty { frontmatter.append("description: \(template.summary)") }
        if !template.argumentHint.isEmpty { frontmatter.append("argument-hint: \(template.argumentHint)") }
        return "---\n" + frontmatter.joined(separator: "\n") + "\n---\n" + template.body + "\n"
    }
}
