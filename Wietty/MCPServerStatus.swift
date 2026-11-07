import Foundation

/// Where the MCP server is in its life, as `MCPServerHost` reports it.
///
/// `running` means the port is bound, not merely that a start was attempted: the
/// host only enters it from Hummingbird's `onServerRunning`, so a port somebody else
/// holds never shows as running. Every case but `stopped` carries the port, so the
/// status bar and Settings can name it without reading the store's configured
/// port, which may already have moved on.
enum MCPServerStatus: Equatable, Sendable {
    case stopped
    case starting(port: Int)
    case running(port: Int)
    case failed(port: Int, message: String)

    /// How the status bar colours the item.
    enum Health: Equatable, Sendable {
        case ok, pending, error
    }

    var health: Health {
        switch self {
        case .running: .ok
        case .starting: .pending
        case .stopped, .failed: .error
        }
    }

    /// The status bar's text: short enough to sit next to other items.
    var summary: String {
        switch self {
        case let .running(port): "MCP 127.0.0.1:\(port)"
        case .starting: "MCP starting"
        case .failed: "MCP not running"
        case .stopped: "MCP stopped"
        }
    }

    /// The status bar's tooltip, which carries the reason a summary leaves out.
    var detail: String {
        switch self {
        case let .running(port): "MCP server listening on http://127.0.0.1:\(port)/mcp"
        case let .starting(port): "MCP server starting on port \(port)"
        case let .failed(port, message): "MCP server did not start on port \(port): \(message)"
        case .stopped: "MCP server is stopped"
        }
    }

    /// The URL a client connects to, only while there is something to connect to.
    var endpointURL: String? {
        if case let .running(port) = self { return "http://127.0.0.1:\(port)/mcp" }
        return nil
    }

    /// Why the server is not running, for the Settings tab.
    var errorMessage: String? {
        if case let .failed(_, message) = self { return message }
        return nil
    }
}
