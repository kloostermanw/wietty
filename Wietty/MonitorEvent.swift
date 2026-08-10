import Foundation

/// An event about one terminal, from libghostty's action callback or from the
/// periodic job poll.
enum MonitorEvent: Equatable, Sendable {
    case title(sessionId: String, name: String)
    case bell(sessionId: String)
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
