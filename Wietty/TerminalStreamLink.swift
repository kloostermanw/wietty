import WiettyShared

/// One connection to a terminal's stream, whatever carries it. Callbacks run on a
/// queue the link owns; a callback that blocks holds the connection back.
///
/// What every link promises:
/// - `onMessage` and `onEnded` are called on the link's own thread or queue, in the
///   order the server sent, one at a time. While one has not returned, nothing more
///   is read from the connection, so a consumer that blocks holds the server back.
/// - The server's `hello` is consumed and never delivered, and neither is `ended` or
///   `error`: those end the link and arrive as `onEnded`, once.
/// - `start()` and `claim` never block the caller on the server: they queue what they
///   write. `send` is the one call that may wait: when a bounded amount of input is
///   already waiting for the server, until the server takes some, or the link ends or
///   stops. Call it only from a thread that may be held back (never the main thread).
///   `send` and `claim` are dropped before `start()` and after an end or a stop.
/// - `stop()` fires no `onEnded`. Called from outside a callback, it returns only when
///   no callback is running, and none comes after it; so it waits for a running
///   callback, and for nothing else. Called from inside one, it cannot wait for that
///   one, and nothing comes after it returns.
protocol TerminalStreamLink: AnyObject, Sendable {
    var onMessage: (@Sendable (StreamMessage) -> Void)? { get set }
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? { get set }
    func start()
    func stop()
    func send(_ bytes: [UInt8])
    func claim(cols: Int, rows: Int)
}
