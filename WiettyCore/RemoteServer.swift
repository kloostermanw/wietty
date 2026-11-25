import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import os
import WiettyShared

/// Logging for the LAN server.
///
/// A viewer is told the status and, for a failure, the reason; neither reaches the
/// person sitting at the Mac that actually refused. This is that Mac's own copy,
/// and `os.Logger` explicitly because Hummingbird's `Logging` module spells its own
/// type the same way.
package enum RemoteLog {
    package static let server = os.Logger(subsystem: "eu.kloosterman.wietty", category: "remote")
}

/// LAN-facing HTTP + WebSocket server. Serves the web client, a token-gated
/// session list, and a token-gated per-session terminal socket bridged to a
/// `ScreenStreaming` implementation. Opt-in and best-effort: startup failures
/// are recorded, never fatal.
@MainActor
package final class RemoteServer {
    package static let defaultPort = 7434

    private let store: ProjectStore
    private let streamer: any ScreenStreaming
    private let token: RemoteAccessToken
    private let host: String
    private let port: Int
    private let closeGrace: Duration
    private let onStartupError: (@MainActor @Sendable (String) -> Void)?
    private var runTask: Task<Void, Never>?

    private(set) var startupError: String?
    /// The port the server is listening on, once it is. The one asked for, or the
    /// one the system chose for port 0, which is how a test gets a free port with
    /// no race.
    package private(set) var boundPort: Int?

    /// - Parameters:
    ///   - host: the address to bind, every interface unless a test binds
    ///     loopback only.
    ///   - closeGrace: how long the server waits for a client to close after the
    ///     last frame (the notice to an old client, `ended` to a version 2 viewer)
    ///     before it closes itself. Shorter only in a test.
    package init(store: ProjectStore, streamer: any ScreenStreaming,
         token: RemoteAccessToken, host: String = "0.0.0.0", port: Int = RemoteServer.defaultPort,
         closeGrace: Duration = RemoteServer.defaultCloseGrace,
         onStartupError: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.store = store
        self.streamer = streamer
        self.token = token
        self.host = host
        self.port = port
        self.closeGrace = closeGrace
        self.onStartupError = onStartupError
    }

    package func start() async {
        guard runTask == nil else { return }
        let expected = token.value
        let host = self.host
        let store = self.store
        let streamer = self.streamer
        let closeGrace = self.closeGrace

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
                let payload = RemoteSessionList.json(projects: store.projects,
                                                     liveLabels: store.liveLabels)
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
        router.post("api/terminals/:tid/activate") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.activateTerminal(store: store, refId: ctx.parameters.get("tid"))
        }
        router.post("api/sessions/:sid/restart") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.restartSession(store: store, sessionId: ctx.parameters.get("sid"))
        }
        router.post("api/sessions/:sid/close") { request, ctx -> Response in
            guard Self.tokenOK(request, expected: expected) else { return Response(status: .unauthorized) }
            return await Self.closeSession(store: store, sessionId: ctx.parameters.get("sid"))
        }

        // WebSocket route, token checked at upgrade time. Protocol version 2; see
        // `docs/remote-access.md`, "The terminal stream (protocol version 2)".
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.ws("attach",
            shouldUpgrade: { request, _ in
                Self.tokenOK(request, expected: expected) ? .upgrade([:]) : .dontUpgrade
            },
            onUpgrade: { inbound, outbound, context in
                let request = context.request
                // The version first: an old client is recognised by its missing
                // `protocol` parameter and is told to update, not attached.
                guard let version = Self.query(request, "protocol") else {
                    await Self.exchange(on: inbound, grace: closeGrace, write: {
                        do {
                            for text in Self.oldClientNotice { try await outbound.write(.text(text)) }
                        } catch { return false }
                        return true
                    }, read: { _ in })
                    return
                }
                guard version == String(StreamProtocol.version) else {
                    let refusal = StreamMessage.error(
                        code: "protocol",
                        message: "This Mac speaks terminal stream protocol version \(StreamProtocol.version).")
                    try? await Self.write(refusal, to: outbound)
                    return
                }
                // Answered rather than closed in silence: a client that is told
                // nothing reports a lost connection and may reconnect, forever.
                guard let session = Self.query(request, "session") else {
                    let refusal = StreamMessage.error(
                        code: "session", message: "No terminal session was named.")
                    try? await Self.write(refusal, to: outbound)
                    return
                }
                let resize = Self.query(request, "resize").flatMap(ResizeMode.init(rawValue:)) ?? .repaint
                await Self.serve(session: session, resize: resize, streamer: streamer,
                                 inbound: inbound, outbound: outbound, grace: closeGrace)
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
            server: .http1WebSocketUpgrade(
                webSocketRouter: wsRouter,
                configuration: .init(ws: WebSocketServerConfiguration(
                    maxFrameSize: Self.maxInboundMessage,
                    // Documented in docs/remote-access.md, so pinned rather than left to
                    // the library's default (the same today): a viewer that has not
                    // answered one ping when the next is due is closed with 1001.
                    autoPing: .enabled(timePeriod: .seconds(30))))),
            configuration: ApplicationConfiguration(
                address: .hostname(host, port: port),
                serverName: "wietty-remote"),
            onServerRunning: { [weak self] channel in
                let port = channel.localAddress?.port
                // Not after a stop that came first.
                await MainActor.run { if self?.runTask != nil { self?.boundPort = port } }
            },
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

    package func stop() {
        runTask?.cancel()
        runTask = nil
        boundPort = nil
    }

    // MARK: - The attach route

    /// The largest frame, and the largest message, a viewer may send: input, so a
    /// paste. One mebibyte; a larger one makes the library close the socket with
    /// 1009 (message too big). Outbound has no limit: a frame is written whole,
    /// whatever its size, which a snapshot of a full history needs.
    package nonisolated static let maxInboundMessage = 1 << 20

    /// What a client with no `protocol` parameter is sent: version 1 text frames,
    /// built by hand because version 1 has no type left in the code. A version 1
    /// client decodes `type`, and `vt` for a `data` message, and shows the text in
    /// its terminal; `ended` then shows the session as ended.
    package nonisolated static let oldClientNotice: [String] = {
        let text = "\r\n\u{1B}[31mThis app is too old for this Mac. Update Wietty on this device.\u{1B}[0m\r\n"
        func json(_ object: [String: String]) -> String {
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data ?? Data(), as: UTF8.self)
        }
        return [json(["type": "data", "vt": text]), json(["type": "ended"])]
    }()

    /// How long a client is given to close after the last frame the server writes to
    /// it, the notice to an old client or `ended` to a version 2 viewer.
    package nonisolated static let defaultCloseGrace: Duration = .seconds(10)

    /// One socket's exchange, from the first frame the server writes to the close.
    ///
    /// `write` is the only thing that writes to the socket. It returns true once it
    /// has written the last frame, and false when it stops for any other reason (a
    /// write failed, its source finished, the handler was cancelled). `read` is
    /// handed each frame the client sends until the last frame is written; after it,
    /// what the client sends is dropped. The two run side by side, and whichever
    /// ends first cancels the other. Returning lets the library send the close frame
    /// and close the socket. Cancelling the handler (the server stopping) ends it at
    /// once.
    ///
    /// **After the last frame the close is left to the client**, which closes when it
    /// reads that frame: the old client on `ended`, the package's
    /// `TerminalStreamConnection` and the browser on `ended` or `error`. Only a
    /// client that has not closed after `grace` is closed by the server. A close the
    /// server sends right after the last frame can be read by the client's
    /// `URLSessionWebSocketTask` ahead of frames it has not handed over yet (it is
    /// when they arrive together, as the notice does with the answer to the
    /// upgrade, and as `hello` and `ended` do for a session that is gone). The task
    /// answers it, the server drops the connection, and the next thing the client
    /// sends (held input, a held claim, a keystroke) fails the task, which then hands
    /// its next receive that error instead of the frames it holds: the client loses
    /// `ended` and reports a lost connection, and an owner that reconnects on a lost
    /// connection tries again.
    ///
    /// A refusal (`error`) is not routed through here: the server writes it and closes
    /// at once. The package's client sends nothing before the `hello`, so there is no
    /// send to fail, and the browser's `WebSocket` hands over every message before it
    /// reports the close.
    private nonisolated static func exchange(on inbound: WebSocketInboundStream, grace: Duration,
                                             write: @escaping @Sendable () async -> Bool,
                                             read: @escaping @Sendable (WebSocketMessage) -> Void) async {
        let lastWritten = OSAllocatedUnfairLock(initialState: false)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                guard await write() else { return }
                lastWritten.withLock { $0 = true }
                try? await Task.sleep(for: grace)
            }
            group.addTask {
                do {
                    for try await frame in inbound.messages(maxSize: maxInboundMessage)
                    where !lastWritten.withLock({ $0 }) {
                        read(frame)
                    }
                } catch {}
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// One accepted version 2 viewer, from the hello to the close.
    ///
    /// The writer drains the viewer's queue in order and is done once it has written
    /// `ended`, which is the last frame: the close is then left to the client (see
    /// `exchange`). It also stops when a write fails or the queue is finished. The
    /// reader hands input and claims to the streamer, and stops when the client
    /// closes, the socket fails or a message is too large. Then the viewer is closed
    /// (detached, queue finished).
    ///
    /// Every way a viewer is sent `ended` comes through here alike: a session that is
    /// gone when the viewer attaches (`hello` and `ended` together), and a session
    /// that ends while it is streamed.
    private nonisolated static func serve(session: String, resize: ResizeMode,
                                          streamer: any ScreenStreaming,
                                          inbound: WebSocketInboundStream,
                                          outbound: WebSocketOutboundWriter,
                                          grace: Duration) async {
        let viewer = AttachedViewer(
            streamer: streamer, session: session, resize: resize,
            greeting: .hello(protocolVersion: StreamProtocol.version, session: nil, resize: nil))
        await exchange(on: inbound, grace: grace, write: {
            while let message = await viewer.queue.next() {
                do { try await write(message, to: outbound) } catch { return false }
                if message == .ended { return true }
            }
            return false
        }, read: { frame in
            let decoded: StreamMessage? = switch frame {
            case let .text(text): StreamCodec.message(from: .text(text))
            case let .binary(buffer):
                StreamCodec.message(from: .binary(Array(buffer.readableBytesView)))
            }
            switch decoded {
            case let .data(bytes) where !bytes.isEmpty:
                streamer.send(session: session, bytes: bytes)
            case let .resize(cols, rows, _):
                // A claim: the hub resizes the terminal and answers it with
                // exactly one `resize` carrying `own: true`.
                viewer.claim(cols: cols, rows: rows)
            default:
                break
            }
        })
        viewer.close()
    }

    private nonisolated static func write(_ message: StreamMessage,
                                          to outbound: WebSocketOutboundWriter) async throws {
        switch StreamCodec.webSocketFrame(for: message) {
        case let .text(text): try await outbound.write(.text(text))
        case let .binary(bytes): try await outbound.write(.binary(ByteBuffer(bytes: bytes)))
        }
    }

    // MARK: - Helpers

    private nonisolated static func tokenOK(_ request: Request, expected: String) -> Bool {
        isAuthorized(token: query(request, "token"), expected: expected)
    }

    /// Pure comparison at the heart of the LAN control server's auth boundary.
    /// A missing/empty `expected` token must never be satisfied by a missing
    /// or empty client token, so this rejects unconditionally in that case.
    package nonisolated static func isAuthorized(token: String?, expected: String) -> Bool {
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

    /// A JSON body under any status, not only `.ok`: a failed activation answers
    /// with the reason it failed, which is worth reading with the status that
    /// carries it.
    private nonisolated static func jsonResponse(_ json: String,
                                                 status: HTTPResponse.Status = .ok) -> Response {
        Response(status: status,
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

    /// What activating a row came to, and what the viewer is told about it.
    ///
    /// One value, decided where the failure happened. The shape this replaces
    /// answered a bare nil for every failure and then read the store a second time
    /// to choose a status from it, which could not tell a store that refused from a
    /// row removed while its shell was opening: that one was answered as "no such
    /// row", telling a viewer its snapshot was stale for a failure that was this
    /// Mac's. It also left the store's reason nowhere.
    package enum ActivateOutcome: Equatable {
        /// No id, or one that is not a UUID. No snapshot this Mac ever sent could
        /// have named it, so the asking is wrong rather than out of date.
        case badRequest
        /// No row has that id: the viewer's snapshot is older than this Mac's
        /// workspace list.
        case notFound
        /// The store refused, carrying the reason it already worded for a person.
        case failed(String)
        /// The store reported success and the row still has no session to attach
        /// to. Answering with the row would send the viewer straight back to the
        /// dead pane this route exists to prevent.
        case noSession
        case ok(JSONValue)

        package var status: HTTPResponse.Status {
            switch self {
            case .badRequest: .badRequest
            case .notFound: .notFound
            case .failed, .noSession: .internalServerError
            case .ok: .ok
            }
        }

        /// The JSON to answer with, or nil for the statuses that say all they have
        /// to say. A failure carries its reason, so a viewer can show more than a
        /// number without anyone walking over to this Mac to read its log; a client
        /// that reads only the status is unaffected.
        package var body: JSONValue? {
            switch self {
            case .badRequest, .notFound: nil
            case let .failed(reason): .object(["error": .string(reason)])
            case .noSession: .object(["error": .string("The row was activated but has no session.")])
            case let .ok(json): json
            }
        }
    }

    /// Gives the row with this id a live session, opening one when it has none, and
    /// answers with its terminal JSON carrying the session id to attach to.
    @MainActor
    private static func activateTerminal(store: ProjectStore, refId: String?) async -> Response {
        let outcome = await activateOutcome(store: store, refId: refId)
        guard let body = outcome.body else { return Response(status: outcome.status) }
        return Self.jsonResponse(body.encodedString(), status: outcome.status)
    }

    /// The activation itself, split from its `Response` so it can be tested without
    /// a socket.
    ///
    /// `ProjectStore.activateThrowing` is what does the work, deliberately, rather
    /// than anything narrower: it is the same call a click on a local row makes, so
    /// a remote click reopens a dead row and re-runs a stopped agent's line exactly
    /// the way the Mac beside it does. That includes focusing the session in the
    /// serving Mac's own pane, which is the price of one implementation rather than
    /// two.
    @MainActor
    package static func activateOutcome(store: ProjectStore, refId: String?) async -> ActivateOutcome {
        guard let refId, let id = UUID(uuidString: refId) else { return .badRequest }
        guard let found = store.session(withRefId: id) else { return .notFound }
        do {
            try await store.activateThrowing(found.ref, in: found.project)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // The viewer is told this too. It is logged here as well because this is
            // the Mac the terminal is on, and a revival that fails has already
            // discarded the row's old screen: there is nothing left on either end to
            // read the reason off afterwards.
            RemoteLog.server.error("""
                activating \(id.uuidString, privacy: .public) failed: \(reason, privacy: .public)
                """)
            return .failed(reason)
        }
        // Re-read: activating a row with no live session gives it a new session id,
        // and that new id is the whole reason a viewer waits for this reply. A row
        // that has gone missing by now really is missing, which is the one case where
        // answering "no such row" after the work is the truth.
        guard let refreshed = store.session(withRefId: id) else { return .notFound }
        guard !refreshed.ref.sessionId.isEmpty else { return .noSession }
        return .ok(Self.terminalJSON(refreshed.ref, in: refreshed.project, store: store))
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
                                     displayLabel: store.displayName(for: ref),
                                     runState: store.runState(for: ref),
                                     needsAttention: store.attention.contains(ref.id),
                                     jobName: store.jobNames[ref.id])
    }
}
