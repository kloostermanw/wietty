import Foundation

/// The copy-and-paste handle for a managed process or test row, encoding the stable
/// identity `(projectId, kind, name)` as a single self-contained string.
///
/// A `ManagedProcess` has no persisted identifier the way a terminal has its
/// `sessionId`: its runtime `id` is a fresh `UUID` regenerated on every config reload
/// and never written to disk, so it cannot survive a paste into a later agent turn.
/// `(projectId, kind, name)` is what stays constant, and because a process and a test
/// may share a name (see `ProcessLogRef.isTest`), the kind has to be part of the
/// handle. The project id is included so the handle resolves globally, the way a
/// terminal `session_id` does, rather than depending on a selected workspace.
///
/// Encoded as `<projectId>:<process|test>:<name>`. The name is a `wietty.json` key and
/// may itself contain a colon, so parsing splits on the first two colons only and keeps
/// the remainder verbatim.
enum ManagedProcessID {
    struct Parsed: Equatable {
        let projectId: UUID
        let name: String
        let isTest: Bool
    }

    static func string(projectId: UUID, name: String, isTest: Bool) -> String {
        "\(projectId.uuidString):\(isTest ? "test" : "process"):\(name)"
    }

    static func parse(_ raw: String) -> Parsed? {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let projectId = UUID(uuidString: String(parts[0])) else { return nil }
        let isTest: Bool
        switch parts[1] {
        case "process": isTest = false
        case "test": isTest = true
        default: return nil
        }
        let name = String(parts[2])
        guard !name.isEmpty else { return nil }
        return Parsed(projectId: projectId, name: name, isTest: isTest)
    }
}
