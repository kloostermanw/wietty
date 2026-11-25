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
/// - `stop()` fires no `onEnded`. Called from outside a callback, it returns only when
///   no callback is running, and none comes after it. Called from inside one, it
///   cannot wait for that one, and nothing comes after it returns.
/// - `send` and `claim` are dropped before `start()` and after an end or a stop.
protocol TerminalStreamLink: AnyObject, Sendable {
    var onMessage: (@Sendable (StreamMessage) -> Void)? { get set }
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? { get set }
    func start()
    func stop()
    func send(_ bytes: [UInt8])
    func claim(cols: Int, rows: Int)
}
