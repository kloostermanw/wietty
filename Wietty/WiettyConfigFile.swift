import Foundation

/// Wietty's user-facing configuration, at `~/.config/wietty/config`.
///
/// The same `key = value` line format as `~/.config/wietty/ghostty.cfg`, and for the
/// same audience: the file lives in the user's `~/.config` and they may well edit it.
/// So it is rewritten key by key rather than regenerated, and a comment or a key this
/// type does not manage survives a write untouched. See `GhosttyOverrideFile`, which
/// this deliberately mirrors.
///
/// Lists (agents, workspaces, per-workspace approvals) are flattened into indexed
/// keys, e.g. `agent.0.name`, `workspace.1.path`, `approved.<uuid>.0`. This type does
/// not know those shapes: it reads and writes flat `key = value` pairs, and the
/// mapping between a domain list and its indexed keys lives with the domain.
struct WiettyConfigFile {
    let url: URL

    /// `~/.config/wietty/config`, beside `ghostty.cfg`.
    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/wietty/config")
    }

    init(url: URL = WiettyConfigFile.defaultURL) {
        self.url = url
    }

    enum WriteError: LocalizedError {
        /// A value (or key) carried a newline, which the one-value-per-line format
        /// cannot hold. Refused rather than written, so the second line does not
        /// reappear as a stray or injected key on the next read.
        case multilineValue(key: String)

        var errorDescription: String? {
            switch self {
            case let .multilineValue(key):
                return "A setting value contains a line break and cannot be saved (\(key))."
            }
        }
    }

    /// Every `key = value` pair in the file, last-wins for a repeated key.
    ///
    /// An absent file reads as empty, and that is not an error: it is the first launch
    /// or a reset. A file that is present but cannot be read (wrong encoding, a partial
    /// write, permissions) throws instead of reading as empty, because the two must not
    /// be confused: treating an unreadable file as empty would let the caller migrate
    /// or seed over it and lose everything it held. See `ProjectStore`'s init.
    func read() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Last wins, so a plain assignment over any earlier value is correct.
            if let pair = Self.pair(in: String(line)) { values[pair.key] = pair.value }
        }
        return values
    }

    /// Rewrites the file so that the managed keys are exactly `pairs`, in the given
    /// order, and everything else the file held (comments, blank lines, and any key
    /// this write does not manage) is preserved.
    ///
    /// A key is managed when it appears in `pairs`, or is listed in `managedKeys`, or
    /// starts with one of `managedPrefixes`. The prefixes are how a list that shrank
    /// drops its stale entries: rewriting two agents where the file held five must
    /// remove `agent.2.*` through `agent.4.*`, none of which appear in `pairs`.
    ///
    /// Creates the file and its directory when absent.
    func write(_ pairs: [(key: String, value: String)],
               managedKeys: Set<String> = [],
               managedPrefixes: [String] = []) throws {
        // Checked before any file is touched, so a value the format cannot hold fails
        // the whole write rather than corrupting the file with a half-written line.
        for pair in pairs where pair.key.containsLineBreak || pair.value.containsLineBreak {
            throw WriteError.multilineValue(key: pair.key)
        }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty
            ? [] : existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let writing = Set(pairs.map(\.key))
        func isManaged(_ key: String) -> Bool {
            writing.contains(key) || managedKeys.contains(key)
                || managedPrefixes.contains { key.hasPrefix($0) }
        }
        // This type's own header and every managed pair go, so the header is written
        // exactly once and a stale entry (a list that shrank, a setting back at its
        // default) does not linger. A comment or an unmanaged pair is left where it is.
        lines.removeAll { Self.isHeader($0) }
        lines.removeAll { Self.pair(in: $0).map { isManaged($0.key) } ?? false }
        // Blank lines at either end are this type's own doing once its header is gone,
        // and would otherwise accumulate on every write.
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }

        for pair in pairs { lines.append("\(pair.key) = \(pair.value)") }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let text = ([Self.header] + lines).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: The format

    /// Says whose file this is, because it lives in a directory the user owns and
    /// nothing else would explain where it came from. One line, so a bug that repeats
    /// it is one line of noise rather than a paragraph. Removed before every write and
    /// re-added, so it is present exactly once.
    private static let header =
        "# Managed by Wietty. Hand-editable: key = value, one per line, # starts a comment. Secrets are never written here."

    private static func isHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("# Managed by Wietty.")
    }

    /// The `key = value` in one line, or nil for a comment, a blank line, or anything
    /// this type does not recognise. Anything returning nil is preserved exactly.
    /// Splits on the first `=`, so a value may itself contain one.
    private static func pair(in line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}

private extension String {
    var containsLineBreak: Bool { contains("\n") || contains("\r") }
}
