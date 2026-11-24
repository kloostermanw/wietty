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
    /// A viewer says "I am active, this is my grid". Answered with a `resize` to every
    /// viewer, `own` true for this one. Unknown ids are ignored.
    func claim(connectionId: UUID, cols: Int, rows: Int)
    func stop()
}
