import Foundation

/// An event about one terminal, from libghostty's action callback or from the
/// periodic job poll.
enum MonitorEvent: Equatable, Sendable {
    case title(sessionId: String, name: String)
    case bell(sessionId: String)
    /// A notification the process asked for by name, through `OSC 9` or `OSC 777`,
    /// rather than the single byte a bell is.
    ///
    /// Separate from `.bell` because the two say different amounts. A bell carries
    /// nothing but that it rang, and shells ring it for ambiguous tab completion; a
    /// notification carries words a program chose to send, which is how coding
    /// agents announce that they are waiting on input. `title` is empty for a bare
    /// `OSC 9;text`, which supplies a body and nothing else.
    case notification(sessionId: String, title: String, body: String)
    case job(sessionId: String, jobName: String)
    case terminated(sessionId: String)

    /// Parses one NDJSON line. Returns nil for malformed input or unknown event
    /// types. Nothing in the app produces these lines today: the events are built
    /// directly. It stays because the wire shape is what a monitor outside this
    /// process would have to emit, and the parser is cheap to keep honest.
    static func decode(line: String) -> MonitorEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let sessionId = object["session_id"] as? String else {
            return nil
        }
        switch type {
        case "title":
            guard let name = object["name"] as? String else { return nil }
            return .title(sessionId: sessionId, name: name)
        case "bell":
            return .bell(sessionId: sessionId)
        case "notification":
            // A missing title is a notification with no title, because that is what
            // `OSC 9;text` is. A missing body is nothing to show, so it is not one.
            guard let body = object["body"] as? String else { return nil }
            return .notification(sessionId: sessionId,
                                 title: object["title"] as? String ?? "",
                                 body: body)
        case "job":
            // job_name may be JSON null (bare shell / no shell integration);
            // treat null or a missing key as "" (meaning "no agent running").
            let jobName = object["job_name"] as? String ?? ""
            return .job(sessionId: sessionId, jobName: jobName)
        case "terminated":
            return .terminated(sessionId: sessionId)
        default:
            return nil
        }
    }
}
