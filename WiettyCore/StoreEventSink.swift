import Foundation

/// Something the store did that the frontend has to react to.
///
/// Four things, which were four optional closures on `ProjectStore` until this type
/// existed. One channel rather than four properties, for a reason that outlives the
/// tidiness: a closure cannot cross a process boundary and a value can. Phase 5 puts
/// the store in a server the frontend talks to over a socket (issue #84), and these
/// are exactly the events that have to travel.
package enum StoreEvent {
    /// A bell arrived on a tracked row, and only when it turned the row's attention
    /// flag on rather than on every bell. A program ringing in a loop is then one
    /// event, and visiting the row re-arms it.
    case bell(project: Project, ref: TerminalRef)

    /// A process asked for a desktop notification on a tracked row, including the
    /// second one on a row that is already flagged.
    ///
    /// Deliberately not the once-per-flag rule `bell` uses. That rule exists because
    /// a shell rings the bell for ambiguous tab completion, so a bell is ambiguous by
    /// nature and a run of them says nothing new. An `OSC 9` is a program choosing to
    /// send words, and an agent that says "waiting for input" and then "build failed"
    /// has said two things; suppressing the second because the row had not been
    /// visited would lose the one that matters.
    case notification(project: Project, ref: TerminalRef, title: String, body: String)

    /// A row's program status started waiting on the user, finished, or failed, under
    /// `.programStatus` only, with the record the row now shows.
    case programStatus(project: Project, ref: TerminalRef, record: ProgramStatusRecord)

    /// The rows whose attention flag has just been cleared, so a notification about a
    /// bell that has been dealt with can be taken back.
    case attentionCleared(Set<UUID>)

    /// A terminal should be put on screen: a row was clicked, an agent called
    /// `select_process`, or an iPad activated a row.
    ///
    /// A request rather than an instruction. The frontend honours it synchronously, so
    /// with a window open the pane moves exactly when it used to. With no frontend
    /// listening nothing happens and the terminal still opens, runs and streams, which
    /// is what phase 5 needs.
    case showTerminal(sessionId: String)
}

/// Delivers `StoreEvent`s to everyone listening, synchronously.
///
/// Synchronous delivery is the point of this type, not an implementation detail. The
/// four closures it replaces were called from inside the store's own mutations, and
/// what reads them decides whether to post a banner by asking whether the app is
/// frontmost and whether that terminal is on screen, both read at the instant of the
/// event. An `AsyncStream` would deliver a turn later, and in between the app can
/// lose focus and the pane can move, so a banner that should have been suppressed
/// gets posted or the reverse. Collapsing four properties into one channel without
/// touching timing is what lets this change claim to change no behaviour.
///
/// The stream arrives in phase 4, when the protocol carries those two answers as part
/// of the event and the decision stops depending on reading live AppKit state at
/// delivery.
@MainActor
package final class StoreEventSink {
    /// Ordered, not a dictionary: `emit` promises subscription order and a
    /// dictionary's values have none.
    private var handlers: [(id: UUID, call: (StoreEvent) -> Void)] = []

    package init() {}

    /// Registers a handler and answers the id that cancels it.
    @discardableResult
    package func subscribe(_ handler: @escaping (StoreEvent) -> Void) -> UUID {
        let id = UUID()
        handlers.append((id: id, call: handler))
        return id
    }

    package func cancel(_ id: UUID) {
        handlers.removeAll { $0.id == id }
    }

    /// Calls every handler before returning, in subscription order.
    ///
    /// The snapshot is deliberate: a handler that subscribes or cancels while being
    /// called changes who hears the next event, not this one.
    package func emit(_ event: StoreEvent) {
        for handler in handlers { handler.call(event) }
    }
}
