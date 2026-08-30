import Foundation

/// Text <-> value helpers for the multi-value fields the Edit workspace page edits
/// as free text: array fields (`shell_init`, `restart_when_changed`) as one entry
/// per line, and the `env` map as one `KEY=VALUE` per line. Kept out of the view so
/// the parsing is pure and has tests.
enum ConfigFieldText {
    /// One array entry per line. Blank lines are dropped, so a trailing newline or a
    /// gap between entries does not become an empty entry the file would carry.
    static func toLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func fromLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// One `KEY=VALUE` per line. A line with no `=`, or an empty key, is skipped.
    /// The value keeps everything after the first `=`, so `A=b=c` maps `A` to `b=c`.
    static func toEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = String(trimmed[trimmed.index(after: eq)...])
        }
        return env
    }

    /// Sorted by key so the text does not reorder itself between two reads of the
    /// same map (`env` is a dictionary).
    static func fromEnv(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }
}
