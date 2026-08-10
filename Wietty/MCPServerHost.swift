import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCP
import NIOCore

/// Hosts the Wietty MCP server over a loopback HTTP endpoint.
///
/// Uses the MCP Swift SDK's `StatelessHTTPServerTransport` (plain JSON
/// request/response, no sessions or SSE, which is all Wietty needs since it
/// sends no server-initiated messages) served by a Hummingbird HTTP server
/// bound to `127.0.0.1`. All tool logic lives in `MCPToolRouter`; this type is
/// only the transport/protocol adapter.
///
/// Connect a client with:
/// `claude mcp add --transport http wietty http://127.0.0.1:<port>/mcp`
@MainActor
final class MCPServerHost {
    static let defaultPort = 7433
    static let serverName = "wietty"
    static let serverVersion = "1.0"
    private static let endpointPath = "mcp"
    private static let maxRequestBytes = 4 * 1024 * 1024

    private let router: MCPToolRouter
    private let port: Int
    private let onStartupError: (@MainActor @Sendable (String) -> Void)?
    private var runTask: Task<Void, Never>?

    /// Populated if the server fails to bind or start.
    private(set) var startupError: String?

    init(router: MCPToolRouter, port: Int = MCPServerHost.defaultPort,
         onStartupError: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.router = router
        self.port = port
        self.onStartupError = onStartupError
    }

    /// Builds the MCP server + transport, wires them to a Hummingbird HTTP
    /// server, and starts serving in a detached task. Returns once the server
    /// task has been launched; it does not block on the run loop.
    func start() async {
        guard runTask == nil else { return }
        do {
            let transport = Self.makeTransport()
            _ = try await Self.makeStartedServer(router: router, transport: transport)

            let application = makeApplication(transport: transport)
            runTask = Task {
                do {
                    try await application.runService()
                } catch is CancellationError {
                    // Normal shutdown via `stop()`; not worth surfacing.
                } catch {
                    let message = "MCP server stopped: \(error.localizedDescription)"
                    await MainActor.run {
                        self.startupError = message
                        self.onStartupError?(message)
                    }
                }
            }
        } catch {
            let message = "MCP server failed to start: \(error.localizedDescription)"
            startupError = message
            onStartupError?(message)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: - MCP server

    /// Builds the transport used for the loopback endpoint.
    ///
    /// Permissive validation pipeline: Wietty binds to loopback only, and
    /// many MCP HTTP clients omit the Origin header that the default localhost
    /// origin validator would otherwise reject.
    static func makeTransport() -> StatelessHTTPServerTransport {
        StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [ContentTypeValidator()])
        )
    }

    /// Builds the MCP server, connects it to `transport`, and registers every
    /// method handler.
    ///
    /// Handlers are registered *after* `Server.start`, not before: `start` runs
    /// the SDK's `registerDefaultHandlers` itself, so anything registered
    /// earlier that shares a method name with a default is silently replaced by
    /// that default. The `initialize` override below depends on this ordering.
    static func makeStartedServer(router: MCPToolRouter, transport: any Transport) async throws -> Server {
        let info = Server.Info(name: serverName, version: serverVersion)
        let capabilities = Server.Capabilities(tools: .init(listChanged: false))
        // `configuration` is spelled out because the `initialize` override below
        // depends on it being non-strict. See the comment on that override.
        let server = Server(name: info.name, version: info.version,
                            capabilities: capabilities, configuration: .default)
        try await server.start(transport: transport)

        // Replace the SDK's default `initialize` handler, which latches an
        // `isInitialized` flag on the first handshake and then answers every
        // later client with `-32600 Invalid Request: Server is already
        // initialized`. That fits a stdio server, where one Server instance
        // serves one connection for its whole lifetime, but not a stateless HTTP
        // transport where each POST can come from a different client.
        //
        // Two consequences of not calling the SDK's `setInitialState`:
        //
        // 1. `isInitialized` stays false forever. That is safe only because the
        //    server above is non-strict: every `checkInitialized()` and
        //    `validateClientCapability` call in the SDK is strict-gated. Under
        //    `.strict` every non-initialize request would fail with "Server is
        //    not initialized". `toolsWorkWithoutAnyHandshake` pins this.
        // 2. `clientInfo` and `clientCapabilities` stay nil. The SDK never reads
        //    either one, and Wietty does not either.
        //
        // The response is built from local copies of the values handed to
        // `Server.init` above, so the two must be kept in step: `instructions` is
        // nil here only because `Server.init` is called without any, and a future
        // `instructions:` argument would otherwise be dropped from every
        // handshake silently. Replacing this handler also disables
        // `Server.start(transport:initializeHook:)`, which the SDK invokes only
        // from the default handler.
        await server.withMethodHandler(Initialize.self) { params in
            Initialize.Result(
                protocolVersion: Self.negotiatedProtocolVersion(clientRequested: params.protocolVersion),
                capabilities: capabilities,
                serverInfo: info,
                instructions: nil
            )
        }

        await server.withMethodHandler(ListTools.self) { _ in
            let descriptors = await router.toolDescriptors()
            let tools = descriptors.map { descriptor in
                Tool(
                    name: descriptor.name,
                    description: descriptor.description,
                    inputSchema: Self.toValue(descriptor.inputSchema)
                )
            }
            return ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let arguments = (params.arguments ?? [:]).mapValues(Self.toJSON)
            do {
                let result = try await router.call(params.name, arguments: arguments)
                return CallTool.Result(
                    content: [.text(text: result.encodedString(), annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return CallTool.Result(
                    content: [.text(text: message, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        return server
    }

    // MARK: - HTTP server

    private func makeApplication(transport: StatelessHTTPServerTransport) -> some ApplicationProtocol {
        let httpRouter = Router()
        let path = Self.endpointPath
        let maxBytes = Self.maxRequestBytes

        httpRouter.on(RouterPath(path), method: .post) { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: maxBytes)
            let bodyData = Data(buffer: buffer)
            var headers: [String: String] = [:]
            for field in request.headers {
                headers[field.name.canonicalName] = field.value
            }
            let mcpRequest = MCP.HTTPRequest(
                method: request.method.rawValue,
                headers: headers,
                body: bodyData.isEmpty ? nil : bodyData,
                path: "/\(path)"
            )
            let mcpResponse = await transport.handleRequest(mcpRequest)

            var responseHeaders = HTTPFields()
            for (name, value) in mcpResponse.headers {
                if let fieldName = HTTPField.Name(name) {
                    responseHeaders[fieldName] = value
                }
            }
            let status = HTTPResponse.Status(code: mcpResponse.statusCode)
            if let data = mcpResponse.bodyData {
                return Response(
                    status: status,
                    headers: responseHeaders,
                    body: ResponseBody(byteBuffer: ByteBuffer(data: data))
                )
            }
            return Response(status: status, headers: responseHeaders)
        }

        return Application(
            router: httpRouter,
            configuration: ApplicationConfiguration(
                address: .hostname("127.0.0.1", port: port),
                serverName: "wietty"
            ),
            logger: Logger(label: "wietty.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
        )
    }

    /// Mirrors the SDK's own negotiation (`Version.negotiate` is internal to the
    /// package): honour the client's version when supported, else answer with
    /// the newest version this build speaks.
    nonisolated static func negotiatedProtocolVersion(clientRequested: String) -> String {
        Version.supported.contains(clientRequested) ? clientRequested : Version.latest
    }

    // MARK: - Value conversion

    nonisolated static func toValue(_ json: JSONValue) -> Value {
        switch json {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .int(value): return .int(value)
        case let .double(value): return .double(value)
        case let .string(value): return .string(value)
        case let .array(values): return .array(values.map(toValue))
        case let .object(members): return .object(members.mapValues(toValue))
        }
    }

    nonisolated static func toJSON(_ value: Value) -> JSONValue {
        switch value {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .int(value): return .int(value)
        case let .double(value): return .double(value)
        case let .string(value): return .string(value)
        case let .data(_, data): return .string(data.base64EncodedString())
        case let .array(values): return .array(values.map(toJSON))
        case let .object(members): return .object(members.mapValues(toJSON))
        }
    }
}
