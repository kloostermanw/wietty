import Foundation

/// One terminal's program status records, under the rules of the Program Status
/// Protocol (`OSC 7501`, sections 4 to 6; see `ProgramStatusReport`).
///
/// A value type with no clock and no idea which terminal it belongs to, so every
/// rule is asserted in a test rather than only visible in the sidebar. What ends a
/// record's life (a prompt, the program exiting, the user looking at it) is the
/// owner's to decide and is applied through `remove`.
struct ProgramStatusRecords: Equatable {
    private struct Entry: Equatable {
        var record: ProgramStatusRecord
        /// When it was last replaced, as an ordinal: what the eviction at the cap
        /// and a tie between children are both decided by.
        var updated: Int
    }

    /// Section 9 allows a terminal any cap of 64 or more; this is the spec's own.
    private static let cap = 256
    /// The key the root record is stored under. The id grammar forbids an empty
    /// id, so it cannot collide with a program's own.
    private static let root = ""

    private var entries: [String: Entry] = [:]
    private var clock = 0

    var isEmpty: Bool { entries.isEmpty }

    mutating func apply(_ report: ProgramStatusReport) {
        switch report {
        case let .set(id, record):
            let key = id ?? Self.root
            if entries[key] == nil, entries.count >= Self.cap,
               let oldest = entries.min(by: { $0.value.updated < $1.value.updated })?.key {
                entries[oldest] = nil
            }
            clock += 1
            entries[key] = Entry(record: record, updated: clock)
        case let .clear(id):
            guard let id else { entries.removeAll(); return }
            entries = entries.filter { $0.key != id && !$0.key.hasPrefix(id + "/") }
        }
    }

    /// Drops every record in one of `states`, for the events that end them.
    mutating func remove(_ states: Set<ProgramStatusState>) {
        entries = entries.filter { !states.contains($0.value.record.state) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// The one record that speaks for the terminal: the most urgent, then the root,
    /// then the most recently updated. Its `app` is filled in from the nearest
    /// ancestor that has one, which section 6 says a record without one inherits.
    ///
    /// The protocol leaves this choice to the terminal. Urgency first, because a
    /// child waiting on the user is the thing to see even while the root is
    /// busy, and an error outranks progress for the same reason.
    var summary: ProgramStatusRecord? {
        guard let (key, entry) = entries.max(by: { Self.ranks($0, below: $1) }) else { return nil }
        var record = entry.record
        if record.app == nil { record.app = inheritedApp(for: key) }
        return record
    }

    private static func urgency(_ state: ProgramStatusState) -> Int {
        switch state {
        case .idle: return 0
        case .done: return 1
        case .working: return 2
        case .error: return 3
        case .blocked: return 4
        }
    }

    private static func ranks(_ lhs: (key: String, value: Entry), below rhs: (key: String, value: Entry)) -> Bool {
        let left = urgency(lhs.value.record.state), right = urgency(rhs.value.record.state)
        if left != right { return left < right }
        if (lhs.key == root) != (rhs.key == root) { return rhs.key == root }
        return lhs.value.updated < rhs.value.updated
    }

    private func inheritedApp(for key: String) -> String? {
        var path = key
        while !path.isEmpty {
            path = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? Self.root
            if let app = entries[path]?.record.app { return app }
        }
        return nil
    }
}
