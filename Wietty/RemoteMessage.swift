import Foundation

/// One message on the LAN terminal socket. Viewers consume raw VT, so a byte
/// source can feed them directly.
enum RemoteMessage: Equatable {
    case resize(cols: Int, rows: Int)
    case data(String)
    /// The session ended or can no longer be streamed; the client should stop.
    case ended
}
