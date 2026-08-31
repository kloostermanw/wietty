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
    var command: String
    /// What the user should do when this check reports action needed. Empty means
    /// none, and the check's name is shown instead, mirroring how an agent's empty
    /// `prefix` means "no prefix" rather than a written-out blank.
    var message: String

    init(command: String, message: String = "") {
        self.command = command
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case command, message
    }

    /// `message` is optional in the file and defaults to empty, so a check written
    /// with only a `command` reads, the same way a test written with only a command
    /// does.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    /// An empty `message` is omitted, so re-encoding a decoded definition does not
    /// add `"message": ""` as noise. `command` is always written.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        if !message.isEmpty { try c.encode(message, forKey: .message) }
    }
}
