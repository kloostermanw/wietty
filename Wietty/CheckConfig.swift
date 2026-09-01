import Foundation

/// One freshness-check definition from the `checks` section of `wietty.json`. A
/// check is a shell command run in the workspace directory: exit 0 means the
/// workspace is fine, a non-zero exit means the check reports that action is
/// needed (for example "run composer install", or a branch that is behind
/// origin). It is the inverse of a `TestConfig`, whose exit 0 means pass; here a
/// clean exit means nothing to do.
///
/// `message` is the human-worded instruction shown in the marker's detail popover
/// when the check trips. When empty the check's own name stands in, so a check
/// still reads sensibly with only a command. The file is the source of truth; the
/// Edit workspace page (`ProjectStore.updateCheck`) is the one path that changes a
/// definition from inside the app.
struct CheckConfig: Codable, Equatable {
    let command: String
    /// What the user should do when this check reports action needed. Empty means
    /// none, and the check's name is shown instead, mirroring how an agent's empty
    /// `prefix` means "no prefix" rather than a written-out blank.
    let message: String
    /// A workspace-relative file whose contents gate re-running the command. When
    /// set, a passing run is remembered against the file's hash, and later ticks
    /// reuse that result without running the command until the file changes. `nil`
    /// (the common case) means the command runs on every tick. A blank or
    /// whitespace-only value is normalized to `nil`, so a blank field in the editor
    /// or a hand-edited file does not turn caching half on. The fields are `let`, so
    /// every value is built through the normalizing init and cannot drift after.
    let watch: String?

    init(command: String, message: String = "", watch: String? = nil) {
        self.command = command
        self.message = message
        self.watch = Self.normalized(watch)
    }

    private enum CodingKeys: String, CodingKey {
        case command, message, watch
    }

    /// `message` and `watch` are optional in the file, so a check written with only a
    /// `command` reads, the same way a test written with only a command does.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        watch = Self.normalized(try c.decodeIfPresent(String.self, forKey: .watch))
    }

    /// A `watch` collapses to `nil` when it is absent or trims to empty, and is
    /// stored trimmed otherwise, so the file path and the editor path agree and a
    /// blank-looking value never survives as a would-be file name.
    private static func normalized(_ watch: String?) -> String? {
        let trimmed = watch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An empty `message` and an absent `watch` are omitted, so re-encoding a decoded
    /// definition does not add `"message": ""` or a null `watch` as noise. `command`
    /// is always written.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        if !message.isEmpty { try c.encode(message, forKey: .message) }
        if let watch, !watch.isEmpty { try c.encode(watch, forKey: .watch) }
    }
}
