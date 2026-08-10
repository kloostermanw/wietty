import Foundation

/// Pure builder for the `/api/sessions` payload: one entry per workspace with
/// its terminal sessions. Kept separate from `RemoteServer` so it can be tested
/// without a running server.
enum RemoteSessionList {
    @MainActor
    static func json(projects: [Project]) -> [[String: Any]] {
        projects.map { project in
            [
                "workspace": project.name,
                "sessions": project.terminals.map { ref in
                    [
                        "id": ref.sessionId,
                        "label": ref.label,
                        "kind": ref.kind.rawValue,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }
}
