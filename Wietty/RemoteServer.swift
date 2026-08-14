import Foundation
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes
import Logging
import NIOCore

/// LAN-facing HTTP + WebSocket server. Serves the web client, a token-gated
/// session list, and a token-gated per-session terminal socket bridged to a
/// `ScreenStreaming` implementation. Opt-in and best-effort: startup failures
/// are recorded, never fatal.
@MainActor
final class RemoteServer {
    static let defaultPort = 7434

    private let store: ProjectStore
    private let streamer: any ScreenStreaming
    private let token: RemoteAccessToken
    private let port: Int
    private let onStartupError: (@MainActor @Sendable (String) -> Void)?
    private var runTask: Task<Void, Never>?

    private(set) var startupError: String?

    init(store: ProjectStore, streamer: any ScreenStreaming,
         token: RemoteAccessToken, port: Int = RemoteServer.defaultPort,
         onStartupError: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.store = store
        self.streamer = streamer
        self.token = token
        self.port = port
        self.onStartupError = onStartupError
    }

    func start() async {
        guard runTask == nil else { return }
        let expected = token.value
        let store = self.store
        let streamer = self.streamer

        // HTTP routes.
        let router = Router()
        router.get("/") { _, _ -> Response in
            Self.fileResponse(resource: "remote_index", ext: "html", contentType: "text/html; charset=utf-8")
        }
        router.get("vendor/xterm.js") { _, _ -> Response in
            Self.fileResponse(resource: "xterm", ext: "js", contentType: "application/javascript")
        }
        router.get("vendor/xterm.css") { _, _ -> Response in
            Self.fileResponse(resource: "xterm", ext: "css", contentType: "text/css")
        }
        router.get("api/sessions") { request, _ -> Response in
            guard Self.tokenOK(request, expected: expected) else {
                return Response(status: .unauthorized)
            }
            let data = await MainActor.run { () -> Data? in
                let payload = RemoteSessionList.json(projects: store.projects)
                return try? JSONSerialization.data(withJSONObject: payload)
            }
            guard let data else { return Response(status: .internalServerError) }
            return Response(status: .ok,
                            headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
        }
        router.get("api/workspaces") { request, _ -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            let json = await MainActor.run { WorkspaceSerializer(store: store).workspaces().encodedString() }
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(string: json)))
        }
        router.post("api/workspaces/:id/terminal") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.openSession(store: store, workspaceId: ctx.parameters.get("id"), kind: .terminal)
        }
        router.post("api/workspaces/:id/claude") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.openSession(store: store, workspaceId: ctx.parameters.get("id"), kind: .claude)
        }
        router.post("api/sessions/:sid/restart") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.restartSession(store: store, sessionId: ctx.parameters.get("sid"))
        }
        router.post("api/sessions/:sid/close") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.closeSession(store: store, sessionId: ctx.parameters.get("sid"))
        }

        // WebSocket route, token checked at upgrade time.
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("attach",
            shouldUpgrade: { request, _ in
                Self.tokenOK(request, expected: expected) ? .upgrade([:]) : .dontUpgrade
            },
            onUpgrade: { inbound, outbound, context in
                guard let session = Self.query(context.request, "session") else { return }
                let sink = WebSocketSink(outbound: outbound)
                // Frames must reach the socket in the order the streamer emits
                // them (a VT byte stream is order critical). Funnel them through
                // one AsyncStream drained by a single sequential writer rather
                // than spawning a Task per message, which would not preserve order.
                let (stream, continuation) = AsyncStream.makeStream(of: RemoteMessage.self)
                let connectionId = streamer.attach(session: session) { message in continuation.yield(message) }
                let writer = Task {
                    for await message in stream { await sink.send(message) }
                }
                do {
                    for try await frame in inbound.messages(maxSize: 1 << 20) {
                        if case let .text(text) = frame,
                           let data = text.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let input = obj["data"] as? String {
                            streamer.send(session: session, text: input)
                        }
                    }
                } catch {}
                streamer.detach(connectionId: connectionId)
                continuation.finish()
                await writer.value
            })

        wsRouter.ws("control",
            shouldUpgrade: { request, _ in
                Self.tokenOK(request, expected: expected) ? .upgrade([:]) : .dontUpgrade
            },
            onUpgrade: { inbound, outbound, _ in
                let (subId, changes) = await MainActor.run { store.workspaceChanges() }
                func snapshotJSON() async -> String {
                    await MainActor.run {
                        let ws = WorkspaceSerializer(store: store).workspaces()
                        // Wrap as {"type":"snapshot","workspaces":[...]}.
                        guard case let .object(m) = ws, let list = m["workspaces"] else { return "{}" }
                        return JSONValue.object(["type": .string("snapshot"), "workspaces": list]).encodedString()
                    }
                }
                // Initial snapshot.
                try? await outbound.write(.text(await snapshotJSON()))
                // Drain the change stream, debounced, until the socket closes.
                let writer = Task {
                    var pending = false
                    for await _ in changes {
                        if pending { continue }
                        pending = true
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        try? await outbound.write(.text(await snapshotJSON()))
                        pending = false
                    }
                }
                // Keep the socket open; ignore any inbound frames.
                do {
                    for try await _ in inbound.messages(maxSize: 1 << 16) {}
                } catch {}
                writer.cancel()
                await MainActor.run { store.cancelWorkspaceChanges(subId) }
            })

        let application = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: ApplicationConfiguration(
                address: .hostname("0.0.0.0", port: port),
                serverName: "wietty-remote"),
            logger: Logger(label: "wietty.remote", factory: { _ in SwiftLogNoOpLogHandler() }))

        runTask = Task {
            do { try await application.runService() }
            catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.startupError = message
                    self.onStartupError?(message)
                }
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: - Helpers

    private nonisolated static func tokenOK(_ request: Request, expected: String) -> Bool {
        isAuthorized(token: query(request, "token"), expected: expected)
    }

    /// Pure comparison at the heart of the LAN control server's auth boundary.
    /// A missing/empty `expected` token must never be satisfied by a missing
    /// or empty client token, so this rejects unconditionally in that case.
    nonisolated static func isAuthorized(token: String?, expected: String) -> Bool {
        !expected.isEmpty && token == expected
    }

    private nonisolated static func query(_ request: Request, _ name: String) -> String? {
        request.uri.queryParameters[name[...]].map(String.init)
    }

    private nonisolated static func fileResponse(resource: String, ext: String, contentType: String) -> Response {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            return Response(status: .notFound)
        }
        return Response(status: .ok,
                        headers: [.contentType: contentType],
                        body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }

    private nonisolated static func jsonResponse(_ json: String) -> Response {
        Response(status: .ok,
                headers: [.contentType: "application/json"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: json)))
    }

    /// Opens a new terminal or claude session in the workspace with the given
    /// id and returns its terminal JSON. `.notFound` if the workspace doesn't
    /// exist, `.internalServerError` if the store action throws.
    @MainActor
    private static func openSession(store: ProjectStore, workspaceId: String?, kind: TerminalKind) async -> Response {
        guard let workspaceId, let project = store.projects.first(where: { $0.id.uuidString == workspaceId }) else {
            return Response(status: .notFound)
        }
        do {
            let ref = try await store.openSessionThrowing(for: project, kind: kind)
            let refreshed = store.projects.first { $0.id == project.id } ?? project
            return Self.jsonResponse(Self.terminalJSON(ref, in: refreshed, store: store).encodedString())
        } catch {
            return Response(status: .internalServerError)
        }
    }

    /// Restarts the tracked session with the given session id and returns its
    /// updated terminal JSON. `.notFound` if no tracked terminal owns that id.
    @MainActor
    private static func restartSession(store: ProjectStore, sessionId: String?) async -> Response {
        guard let sessionId,
              store.projects.contains(where: { $0.terminals.contains { $0.sessionId == sessionId } }) else {
            return Response(status: .notFound)
        }
        do {
            let ref = try await store.restart(sessionId: sessionId)
            guard let project = store.projects.first(where: { $0.terminals.contains { $0.id == ref.id } }) else {
                return Response(status: .internalServerError)
            }
            return Self.jsonResponse(Self.terminalJSON(ref, in: project, store: store).encodedString())
        } catch {
            return Response(status: .internalServerError)
        }
    }

    /// Closes the tracked session with the given session id, returning
    /// `{"closed":true}`. `.notFound` if no tracked terminal owns that id.
    @MainActor
    private static func closeSession(store: ProjectStore, sessionId: String?) async -> Response {
        guard let sessionId,
              store.projects.contains(where: { $0.terminals.contains { $0.sessionId == sessionId } }) else {
            return Response(status: .notFound)
        }
        do {
            try await store.closeSession(sessionId: sessionId)
            return Self.jsonResponse(JSONValue.object(["closed": .bool(true)]).encodedString())
        } catch {
            return Response(status: .internalServerError)
        }
    }

    @MainActor
    private static func terminalJSON(_ ref: TerminalRef, in project: Project, store: ProjectStore) -> JSONValue {
        WorkspaceSerializer.terminal(ref, projectId: project.id, projectName: project.name,
                                     runState: store.runState(for: ref),
                                     needsAttention: store.attention.contains(ref.id),
                                     jobName: store.jobNames[ref.id])
    }
}

/// Serializes outbound WebSocket writes and maps `RemoteMessage` to the wire
/// JSON the web client expects.
private actor WebSocketSink {
    private let outbound: WebSocketOutboundWriter
    init(outbound: WebSocketOutboundWriter) { self.outbound = outbound }

    func send(_ message: RemoteMessage) async {
        let object: [String: Any]
        switch message {
        case let .resize(cols, rows): object = ["type": "resize", "cols": cols, "rows": rows]
        case let .data(vt): object = ["type": "data", "vt": vt]
        case .ended: object = ["type": "ended"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await outbound.write(.text(text))
    }
}
