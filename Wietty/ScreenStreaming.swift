import Foundation

/// The surface `RemoteServer` and `ContentView` depend on for terminal streaming.
/// `session` is a session id, opaque to everything here.
protocol ScreenStreaming: AnyObject, Sendable {
    @discardableResult
    func attach(session: String, onMessage: @escaping @Sendable (RemoteMessage) -> Void) -> UUID
    func detach(connectionId: UUID)
    func send(session: String, text: String)
    func stop()
}
