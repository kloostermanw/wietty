import Foundation

/// Pure builder for the `/api/sessions` payload: one entry per workspace with
/// its terminal sessions. Kept separate from `RemoteServer` so it can be tested
/// without a running server.
enum RemoteSessionList {
    /// `liveLabels` are the live agent-reported titles keyed by terminal id (see
    /// `ProjectStore.liveLabels`), applied on top of each row's stored name so a
    /// client sees the same title this app's sidebar does. Defaulted to none for a
    /// caller with no overrides to apply. Issue #60.
    @MainActor
    static func json(projects: [Project], liveLabels: [UUID: String] = [:]) -> [[String: Any]] {
        projects.map { project in
            [
                "workspace": project.name,
                "sessions": project.terminals.map { ref in
                    [
                        "id": ref.sessionId,
                        "label": ref.displayName(liveLabel: liveLabels[ref.id]),
                        "kind": ref.kind.rawValue,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }
}
