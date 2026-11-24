import Foundation
import WiettyShared

/// The surface `RemoteServer` depends on for terminal streaming. `session` is a
/// session id, opaque to everything here.
package protocol ScreenStreaming: AnyObject, Sendable {
    /// Registers a viewer of `session` and sends it the grid and a snapshot, then
    /// the stream. `resize` is what it wants when the grid changes later.
    @discardableResult
    func attach(session: String, resize: ResizeMode,
                onMessage: @escaping @Sendable (StreamMessage) -> Void) -> UUID
    /// Attaches a viewer that is never dropped. `write` is called with each message in
    /// order and may block: while it does, the thread that reads the pty waits.
    @discardableResult
    func attachLocal(session: String, resize: ResizeMode,
                     write: @escaping @Sendable (StreamMessage) -> Void) -> UUID
    func detach(connectionId: UUID)
    /// Input, byte exact. Never touches the main actor.
    func send(session: String, bytes: [UInt8])
    /// Sends this one viewer a `resize` and a `snapshot`, joined to the stream.
    ///
    /// Always answered: either the snapshot comes, or `onUnavailable` is called
    /// once no snapshot can (the viewer or its session is gone, or no snapshot
    /// could be built). The answer comes later, not before this returns, because
    /// the caller is usually inside a delivery to that very viewer.
    func resync(connectionId: UUID, onUnavailable: @escaping @Sendable () -> Void)
    /// A viewer says "I am active, this is my grid".
    ///
    /// A grid other than the one in force becomes it, and every viewer is sent a
    /// `resize`, `own` true for this one and false for the others. The grid in force
    /// already is answered to this viewer alone, with one `resize` whose `own` is
    /// true. Either way the claimant gets exactly one answer. An unknown or detached
    /// id, or a `cols` or `rows` outside 1...10,000, is ignored without an answer.
    func claim(connectionId: UUID, cols: Int, rows: Int)
    func stop()
}
