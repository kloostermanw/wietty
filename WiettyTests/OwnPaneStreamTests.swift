import Darwin
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

// MARK: Support

/// Lock-guarded bytes, appended from a reader thread and read from the test.
private final class ByteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []
    func append(_ bytes: [UInt8]) { lock.lock(); storage += bytes; lock.unlock() }
    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return storage }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// Lock-guarded messages a local viewer was written.
private final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StreamMessage] = []
    func add(_ message: StreamMessage) { lock.lock(); storage.append(message); lock.unlock() }
    var messages: [StreamMessage] { lock.lock(); defer { lock.unlock() }; return storage }
    /// The payloads of `snapshot` and `data`, in order: what a surface would be fed.
    var fed: [UInt8] {
        messages.flatMap { message -> [UInt8] in
            switch message {
            case .snapshot(let bytes), .data(let bytes): return bytes
            default: return []
            }
        }
    }
}

/// Lock-guarded strings, for reports made off the main actor.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ text: String) { lock.lock(); storage.append(text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// The bundled `wietty-pty`, started the way libghostty starts a surface's command:
/// through a shell, from the command string `PaneBridges` built. Its stdout is read
/// by a thread of its own into `output`, so it never fills and holds the stream.
private final class HelperProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let outputPipe = Pipe()
    let output = ByteLog()

    init(command: String) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + command]
        process.standardInput = input
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let fd = outputPipe.fileHandleForReading.fileDescriptor
        let output = self.output
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                output.append(Array(buffer[0..<count]))
            }
        }
        reader.start()
    }

    /// What the surface would write to the helper's tty when a key is typed.
    func type(_ bytes: [UInt8]) {
        guard process.isRunning else { return }
        input.fileHandleForWriting.write(Data(bytes))
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

/// A surface host with no libghostty: it builds each surface's bridge exactly as
/// `GhosttySurfaceHost` does (`PaneBridges`), and runs the real helper in place of
/// the surface, so everything between the pty and the helper's stdout is real.
///
/// With `realHelpers` false, a plain socket connected to the bridge stands in for the
/// helper (`sockets`), for a test that needs many terminals fast.
@MainActor
private final class BridgedHost: TerminalSurfaceHosting {
    let bridges: PaneBridges
    let realHelpers: Bool
    private(set) var helpers: [String: HelperProcess] = [:]
    private(set) var sockets: [String: UnixTestSocket] = [:]
    private(set) var destroyed: [String] = []

    init(serverPath: String, realHelpers: Bool = true) throws {
        bridges = PaneBridges(helperPath: try bundledHelperURL().path, serverPath: serverPath)
        self.realHelpers = realHelpers
    }

    var onTitle: (@MainActor (String, String) -> Void)?
    var onBell: (@MainActor (String) -> Void)?
    var onDesktopNotification: (@MainActor (String, String, String) -> Void)?
    var onResized: (@MainActor (String, TerminalSize) -> Void)?
    var onCloseRequested: (@MainActor (String) -> Void)?
    var onInput: (@MainActor (String) -> Void)?
    var desktopNotifications: (effective: Bool, userConfig: Bool) { (true, true) }
    var graphemeClustering: Bool { true }
    func reloadConfig() {}
    func size(id: String) -> TerminalSize? { nil }

    func createSurface(id: String, directory: URL, title: String?) throws {
        let command = try bridges.open(session: id)
        do {
            if realHelpers {
                helpers[id] = try HelperProcess(command: command)
            } else {
                let path = try #require(helperSocketPath(of: id))
                sockets[id] = try UnixTestSocket(connectingTo: path)
            }
        } catch {
            bridges.close(session: id)
            throw error
        }
    }

    func destroySurface(id: String) {
        destroyed.append(id)
        bridges.close(session: id)
        helpers.removeValue(forKey: id)?.terminate()
        sockets.removeValue(forKey: id)?.close()
    }

    func helperSocketPath(of session: String) -> String? {
        bridges.bridge(for: session)?.bridge.helperSocketPath
    }

    /// Ends every helper a test left running; the stack's own teardown has stopped
    /// their bridges by then.
    func terminateAll() {
        for helper in helpers.values { helper.terminate() }
        helpers = [:]
        for socket in sockets.values { socket.close() }
        sockets = [:]
    }
}

/// Waits for `condition` without holding the main actor, so the stack's own main
/// actor work (a reap, a display request) can run meanwhile.
@MainActor
private func eventually(within seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// The bytes after the last full reset in `bytes`: the newest snapshot and what
/// followed it.
private func sinceLastReset(_ bytes: [UInt8]) -> [UInt8]? {
    let reset = TerminalPaint.hardReset
    guard bytes.count >= reset.count else { return nil }
    for start in stride(from: bytes.count - reset.count, through: 0, by: -1)
    where Array(bytes[start..<(start + reset.count)]) == reset {
        return Array(bytes[start...])
    }
    return nil
}

private func occurrences(of needle: [UInt8], in bytes: [UInt8]) -> Int {
    guard bytes.count >= needle.count else { return 0 }
    var count = 0
    for start in 0...(bytes.count - needle.count) where Array(bytes[start..<(start + needle.count)]) == needle {
        count += 1
    }
    return count
}

private let folder = URL(fileURLWithPath: "/tmp")

// MARK: End to end

/// The own pane's route with real parts and nothing faked between the pty and the
/// helper: a real pty, relay, hub, `LocalStreamServer`, `LocalSocketLink`,
/// `TerminalBridge` and the bundled `wietty-pty`, wired by the real `GhosttyStack`
/// and `PaneBridges`. Only the libghostty surface is missing: the helper's stdout
/// stands where it would read.
@MainActor
@Suite struct OwnPaneStreamTests {
    @MainActor private struct Rig {
        let host: BridgedHost
        let stack: GhosttyStack
        let serverPath: String
        var service: GhosttyService { stack.ghosttyService! }

        func open(_ command: String?) async throws -> (session: String, helper: HelperProcess) {
            let session = try await stack.service.open(folder: folder, existingWindowId: nil,
                                                       command: command, badge: nil).sessionId
            return (session, try #require(host.helpers[session]))
        }

        /// For a rig with `realHelpers` false: the session and the socket standing in
        /// for its helper.
        func openWithSocket(_ command: String?) async throws -> (session: String, socket: UnixTestSocket) {
            let session = try await stack.service.open(folder: folder, existingWindowId: nil,
                                                       command: command, badge: nil).sessionId
            return (session, try #require(host.sockets[session]))
        }

        func tearDown() {
            stack.shutDown()
            host.terminateAll()
        }
    }

    /// A long wait for the pane, so a test sees the pane's own attach start the read.
    private func rig(readDelay: TimeInterval = 30, realHelpers: Bool = true) throws -> Rig {
        let path = testServerSocketPath()
        let host = try BridgedHost(serverPath: path, realHelpers: realHelpers)
        let stack = GhosttyStack(host: host, localSocketPath: path, readDelay: readDelay)
        try #require(stack.setupError == nil)
        return Rig(host: host, stack: stack, serverPath: path)
    }

    /// What the child writes reaches the helper's stdout exactly: bytes that are
    /// not UTF-8 included, and the pty's own `\r\n`.
    @Test func outputOfTheChildReachesTheHelperByteForByte() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let (_, helper) = try await rig.open(#"printf '\303\050\342\202 out-%s\n' $((2+3)); sleep 30"#)
        let expected: [UInt8] = [0xC3, 0x28, 0xE2, 0x82, 0x20] + Array("out-5\r\n".utf8)
        #expect(await eventually { occurrences(of: expected, in: helper.output.bytes) == 1 })
    }

    /// Bytes on the helper's stdin, which is where libghostty writes a key, reach the
    /// child: the marker is arithmetic, so only a shell that ran the line can print it.
    @Test func inputOnTheHelpersStdinReachesTheChild() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let (_, helper) = try await rig.open(#"echo ready; read line; eval "$line"; sleep 30"#)
        #expect(await eventually { helper.output.text.contains("ready") })
        helper.type(Array("echo typed-$((30+3))\n".utf8))
        #expect(await eventually { helper.output.text.contains("typed-33") })
    }

    /// Control C typed into the pane reaches the child as a signal, through the
    /// pty's line discipline, as from any terminal.
    @Test func controlCReachesTheChildAsASignal() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let (_, helper) = try await rig.open(
            #"trap 'echo got-int-$((1+1)); exit 0' INT; echo ready; while :; do sleep 0.1; done"#)
        #expect(await eventually { helper.output.text.contains("ready") })
        helper.type([0x03])
        #expect(await eventually { helper.output.text.contains("got-int-2") })
    }

    /// The pane's first snapshot of a fresh terminal is the empty screen: the pty is
    /// read only after the pane attached, so nothing is folded into it. Fed to a
    /// fresh terminal, it leaves a blank screen with the cursor at home.
    @Test func theFirstSnapshotOfAFreshTerminalIsEmpty() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let (_, helper) = try await rig.open(#"read go; echo late-$((4+4)); sleep 30"#)
        #expect(await eventually { helper.output.bytes.starts(with: TerminalPaint.hardReset) })
        // Settled: the snapshot is all there is until the child is told to go.
        var settled: [UInt8] = []
        _ = await eventually {
            let now = helper.output.bytes
            defer { settled = now }
            return now == settled && !now.isEmpty
        }
        let fresh = try GhosttyVtTerminal(size: GhosttyService.initialSize, scrollbackLines: 100)
        fresh.write(helper.output.bytes)
        #expect(fresh.text(maxLines: 100) == "")
        #expect(fresh.cursor == (x: 0, y: 0))
        helper.type(Array("go\n".utf8))
        #expect(await eventually { helper.output.text.contains("late-8") })
    }

    /// The server drops a pane that stalls during a control message; the link then
    /// ends as a lost connection while the terminal lives, and the bridge is given a
    /// new link at once. The new attach brings a snapshot, then live output, and fed
    /// from that snapshot on, a fresh terminal shows exactly what the server's model
    /// holds: nothing the child wrote meanwhile is lost.
    @Test func aReconnectDeliversASnapshotAndThenLiveOutputWithNothingLost() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let (session, helper) = try await rig.open("""
            read go; i=0; while [ $i -lt 40 ]; do i=$((i+1)); echo tick-$i; sleep 0.03; done; \
            echo done-$((1+1)); sleep 30
            """)
        #expect(await eventually { helper.output.bytes.starts(with: TerminalPaint.hardReset) })
        helper.type(Array("go\n".utf8))
        #expect(await eventually { helper.output.text.contains("tick-5") })
        let server = try #require(rig.stack.localServer)
        // What the server does to a pane that stalls: it ends the connection.
        let dropped = server.inspectConnections { shutdown($0, SHUT_RDWR) }
        #expect(dropped.count == 1)
        #expect(await eventually { helper.output.text.contains("done-2") })
        #expect(rig.host.bridges.bridge(for: session)?.linkCount == 2)
        #expect(occurrences(of: TerminalPaint.hardReset, in: helper.output.bytes) == 2)

        let fromSnapshot = try #require(sinceLastReset(helper.output.bytes))
        let fresh = try GhosttyVtTerminal(size: GhosttyService.initialSize, scrollbackLines: 1000)
        fresh.write(fromSnapshot)
        let model = try #require(rig.service.screenModel(for: session))
        #expect(fresh.text(maxLines: 100) == model.text(maxLines: 100))
        #expect(model.text(maxLines: 100).contains("tick-40"))
    }

    /// Closing a terminal stops its bridge and unlinks its socket, and the helper,
    /// which is the surface's child, goes. Quitting (`shutDown`) stops the server and
    /// unlinks its socket: a clean quit leaves no socket file of the server's or of
    /// any bridge's in the temp directory.
    @Test func teardownLeavesNoSocketFileBehind() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        let (first, firstHelper) = try await rig.open("sleep 30")
        let (second, _) = try await rig.open("sleep 30")
        let firstPath = try #require(rig.host.helperSocketPath(of: first))
        let secondPath = try #require(rig.host.helperSocketPath(of: second))
        #expect(FileManager.default.fileExists(atPath: firstPath))

        try await rig.stack.service.close(sessionId: first)
        #expect(FileManager.default.fileExists(atPath: firstPath) == false)
        #expect(await eventually { !firstHelper.process.isRunning })

        rig.tearDown()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
        for path in [rig.serverPath, firstPath, secondPath] {
            #expect(!names.contains((path as NSString).lastPathComponent), "\(path) is left behind")
        }
    }

    /// A terminal whose child exits ends its stream: the pane's link is told
    /// `ended` and is not made again, the terminal is reported terminated (which is
    /// what the stopped screen comes from), and the bridge is stopped, so the helper
    /// exits with the child and its socket file goes, as when the relay owned it. The
    /// surface is not destroyed: Restart (discard, then open) still finds and frees it.
    @Test func aChildThatExitsEndsTheStreamAndLetsItsHelperGo() async throws {
        let rig = try rig()
        defer { rig.tearDown() }
        var events: [MonitorEvent] = []
        rig.stack.monitor.start { events.append($0) }
        let (session, helper) = try await rig.open("echo bye-$((6+6)); exit 0")
        let bridgePath = try #require(rig.host.helperSocketPath(of: session))
        #expect(await eventually { events.contains(.terminated(sessionId: session)) })
        #expect(helper.output.text.contains("bye-12"))
        #expect(await eventually { !FileManager.default.fileExists(atPath: bridgePath) })
        #expect(await eventually { !helper.process.isRunning })
        #expect(rig.host.bridges.bridge(for: session)?.linkCount == 1)
        #expect(rig.host.destroyed.isEmpty)

        // Restart: the store discards the stopped terminal and opens a new one.
        await rig.stack.service.discard(sessionId: session)
        #expect(rig.host.destroyed == [session])
        let (_, again) = try await rig.open("echo again-$((3+3)); sleep 30")
        #expect(await eventually { again.output.text.contains("again-6") })
    }

    /// What a live local terminal costs the app in descriptors, counted: its pty's
    /// master, the socket its bridge accepted from the helper (the bridge's listener
    /// is closed once it has), its link's socket and the server's end of it. Four,
    /// where libghostty's surface adds its own in the app. Counted over the whole
    /// descriptor table before and after, less the sockets standing in for the
    /// helpers; other suites open descriptors meanwhile, which can only add, so the
    /// least of three rounds is the measurement.
    @Test func aLiveTerminalCostsAtMostFourDescriptors() async throws {
        let count = 16
        var least = Int.max
        for _ in 0..<3 {
            let rig = try rig(realHelpers: false)
            let before = Self.openDescriptors()
            var sockets: [UnixTestSocket] = []
            for _ in 0..<count {
                sockets.append(try await rig.openWithSocket("echo up-$((1+1)); sleep 30").socket)
            }
            var seen = [Int32: String]()
            let arrived = await eventually(within: 20) {
                for socket in sockets where !(seen[socket.fd] ?? "").contains("up-2") {
                    var readable = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&readable, 1, 0) > 0 else { continue }
                    var buffer = [UInt8](repeating: 0, count: 1 << 16)
                    let got = read(socket.fd, &buffer, buffer.count)
                    if got > 0 { seen[socket.fd, default: ""] += String(decoding: buffer[0..<got], as: UTF8.self) }
                }
                return seen.values.filter { $0.contains("up-2") }.count == count
            }
            #expect(arrived)
            let after = Self.openDescriptors()
            let added = after.subtracting(before).subtracting(sockets.map(\.fd)).count
            least = min(least, added)
            rig.tearDown()
        }
        print("MEASURE descriptors per live local terminal: \(Double(least) / Double(count))")
        #expect(least <= 4 * count)
    }

    private static func openDescriptors() -> Set<Int32> {
        let top = min(getdtablesize(), 1 << 16)
        return Set((0..<top).filter { fcntl($0, F_GETFD) != -1 })
    }

    /// Every live terminal's pane holds a connection to the server for as long as it
    /// lives, so more than the old cap of 64 must each get their own stream. Plain
    /// sockets stand in for the helpers, to keep it fast.
    @Test func moreThan64LiveTerminalsEachReceiveTheirOwnOutput() async throws {
        let rig = try rig(realHelpers: false)
        defer { rig.tearDown() }
        let count = 70
        var sessions: [String] = []
        for index in 0..<count {
            let (session, _) = try await rig.openWithSocket("printf 'own-%s-end' \(index); sleep 30")
            sessions.append(session)
        }
        #expect(await eventually(within: 20) { rig.stack.localServer?.connectionCount == count })
        var received = [String: [UInt8]]()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, received.count < count
                || sessions.enumerated().contains(where: { index, session in
                    !String(decoding: received[session] ?? [], as: UTF8.self).contains("own-\(index)-end")
                }) {
            for session in sessions {
                guard let socket = rig.host.sockets[session] else { continue }
                var readable = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
                guard poll(&readable, 1, 0) > 0 else { continue }
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                let got = read(socket.fd, &buffer, buffer.count)
                if got > 0 { received[session, default: []] += buffer[0..<got] }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        for (index, session) in sessions.enumerated() {
            let text = String(decoding: received[session] ?? [], as: UTF8.self)
            #expect(text.contains("own-\(index)-end"), "terminal \(index) did not get its output")
            #expect(text.components(separatedBy: "own-").count == 2, "terminal \(index) got another's")
        }
    }
}

// MARK: When the pty is read

/// Decision P2, and the census before the surface, at the level of the stack, with
/// the hub's local viewer attached directly.
@MainActor
@Suite struct OwnPaneReadStartTests {
    /// A child that prints at once produces nothing in the model until the pane's
    /// viewer attaches; the viewer then receives every byte, so the snapshot and the
    /// data it is sent, fed to a fresh terminal, show what the model shows.
    @Test func aTerminalIsReadOnlyOnceItsPaneAttached() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost(), readDelay: 30)
        defer { stack.shutDown() }
        let session = try await stack.service.open(folder: folder, existingWindowId: nil,
                                                   command: "echo p2-$((9+9)); sleep 30",
                                                   badge: nil).sessionId
        let model = try #require(stack.ghosttyService?.screenModel(for: session))
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.text(maxLines: 10) == "")

        let log = MessageLog()
        let viewer = stack.hub.attachLocal(session: session, resize: .reflow) { log.add($0) }
        defer { stack.hub.detach(connectionId: viewer) }
        #expect(await eventually { model.text(maxLines: 10).contains("p2-18") })
        #expect(await eventually { String(decoding: log.fed, as: UTF8.self).contains("p2-18") })
        guard case .resize = log.messages.first, case .snapshot = log.messages.dropFirst().first else {
            Issue.record("the attach did not start with a resize and a snapshot: \(log.messages.prefix(2))")
            return
        }
        let fresh = try GhosttyVtTerminal(size: GhosttyService.initialSize, scrollbackLines: 100)
        fresh.write(log.fed)
        #expect(fresh.text(maxLines: 10) == model.text(maxLines: 10))
    }

    /// With no pane, the terminal is read once the wait runs out, and that is
    /// reported as an error (logged, by default).
    @Test func withNoPaneTheTerminalIsReadAfterTheWait() async throws {
        let seen = ByteLog()
        let reports = Reports()
        let service = GhosttyService(host: FakeSurfaceHost(), readDelay: 0.6,
                                     reportUnattachedRead: { reports.add($0) },
                                     onOutput: { _, bytes in seen.append(bytes) },
                                     onTerminated: { _ in })
        defer { service.closeAll() }
        let opened = Date()
        let session = try await service.open(folder: folder, existingWindowId: nil,
                                             command: "echo late-$((3+4)); sleep 30",
                                             badge: nil).sessionId
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.bytes.isEmpty)
        #expect(reports.all.isEmpty)
        #expect(await eventually { seen.text.contains("late-7") })
        #expect(Date().timeIntervalSince(opened) >= 0.55)
        #expect(reports.all.count == 1)
        #expect(reports.all.first?.contains(session) == true)
    }

    /// A pane that attaches after the wait ran out, and the terminal was read without
    /// it, gets what the child printed meanwhile in its snapshot: nothing of it is
    /// lost to the pane, the model holds it.
    @Test func aPaneThatAttachesAfterTheWaitGetsTheEarlierOutputInItsSnapshot() async throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost(), readDelay: 0.3)
        defer { stack.shutDown() }
        let session = try await stack.service.open(folder: folder, existingWindowId: nil,
                                                   command: "echo early-$((5+6)); sleep 30",
                                                   badge: nil).sessionId
        let model = try #require(stack.ghosttyService?.screenModel(for: session))
        #expect(await eventually { model.text(maxLines: 10).contains("early-11") })

        let log = MessageLog()
        let viewer = stack.hub.attachLocal(session: session, resize: .reflow) { log.add($0) }
        defer { stack.hub.detach(connectionId: viewer) }
        #expect(await eventually { log.messages.count >= 2 })
        guard case let .snapshot(bytes)? = log.messages.dropFirst().first else {
            Issue.record("no snapshot second: \(log.messages.prefix(2))")
            return
        }
        let fresh = try GhosttyVtTerminal(size: GhosttyService.initialSize, scrollbackLines: 100)
        fresh.write(bytes)
        #expect(fresh.text(maxLines: 10).contains("early-11"))
    }

    /// A terminal closed before its pane attached and before the wait ran out is
    /// never read, and nothing is reported for it.
    @Test func aTerminalClosedBeforeEitherIsNeverRead() async throws {
        let seen = ByteLog()
        let reports = Reports()
        let service = GhosttyService(host: FakeSurfaceHost(), readDelay: 0.3,
                                     reportUnattachedRead: { reports.add($0) },
                                     onOutput: { _, bytes in seen.append(bytes) },
                                     onTerminated: { _ in })
        defer { service.closeAll() }
        let session = try await service.open(folder: folder, existingWindowId: nil,
                                             command: "echo never-$((1+1)); sleep 30",
                                             badge: nil).sessionId
        try await service.close(sessionId: session)
        try await Task.sleep(for: .milliseconds(700))
        #expect(seen.bytes.isEmpty)
        #expect(reports.all.isEmpty)
        // Too late now, as for the pane: nothing starts it.
        service.localViewerAttached(session: session)
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.bytes.isEmpty)
    }

    /// The read start is handed out once, whoever asks first.
    @Test func theReadStartIsTakenOnce() {
        let shared = SharedTerminalState()
        let ran = Reports()
        shared.register(readStart: { ran.add("ran") }, for: "gt:x")
        shared.takeReadStart(for: "gt:x")?()
        shared.takeReadStart(for: "gt:x")?()
        #expect(ran.all == ["ran"])
    }

    /// The session is in the census before the surface is asked for, because the
    /// pane's bridge can attach while `createSurface` runs: an attach made then gets
    /// a snapshot, not `ended`.
    @Test func aPaneThatAttachesWhileItsSurfaceIsCreatedGetsASnapshot() async throws {
        let host = FakeSurfaceHost()
        let stack = GhosttyStack.testing(host: host, readDelay: 30)
        defer { stack.shutDown() }
        let log = MessageLog()
        var viewer: UUID?
        host.whileCreating = { session in
            viewer = stack.hub.attachLocal(session: session, resize: .reflow) { log.add($0) }
        }
        _ = try await stack.service.open(folder: folder, existingWindowId: nil,
                                         command: "sleep 30", badge: nil)
        defer { if let viewer { stack.hub.detach(connectionId: viewer) } }
        let messages = log.messages
        #expect(!messages.contains { if case .ended = $0 { true } else { false } })
        #expect(messages.contains { if case .snapshot = $0 { true } else { false } })
    }
}

// MARK: The bridge's owner

/// A link the test ends by hand.
private final class ScriptedLink: TerminalStreamLink, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var onMessage: (@Sendable (StreamMessage) -> Void)?
    var onEnded: (@Sendable (TerminalEndReason) -> Void)?
    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func start() { lock.lock(); started = true; lock.unlock() }
    func stop() {}
    func send(_ bytes: [UInt8]) {}
    func claim(cols: Int, rows: Int) {}
    func end(_ reason: TerminalEndReason) { onEnded?(reason) }
}

private final class ScriptedLinks: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScriptedLink] = []
    var now: TimeInterval = 0
    var all: [ScriptedLink] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { all.count }
    func make() -> any TerminalStreamLink {
        let link = ScriptedLink()
        lock.lock(); storage.append(link); lock.unlock()
        return link
    }
    var clock: TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
}

/// `OwnPaneBridge`: which ends make a new link, and how soon.
@Suite struct OwnPaneBridgeTests {
    private func owner(_ links: ScriptedLinks,
                       backoff: ReconnectBackoff = ReconnectBackoff(initial: 0.3, cap: 0.6, resetAfter: 10))
        throws -> (OwnPaneBridge, UnixTestSocket) {
        let owner = try OwnPaneBridge(session: "gt:own", serverPath: "/nonexistent",
                                      helperSocketPath: shortSocketPath("opb"), backoff: backoff,
                                      now: { links.clock }, makeLink: { links.make() })
        let helper = try UnixTestSocket(connectingTo: owner.bridge.helperSocketPath)
        #expect(waitUntil { links.all.first?.isStarted == true })
        return (owner, helper)
    }

    @Test func theWaitGrowsFromNothingToItsCap() {
        let backoff = ReconnectBackoff.standard
        #expect((0..<8).map { backoff.delay(forAttempt: $0) } == [0, 0.25, 0.5, 1, 2, 4, 5, 5])
        #expect(backoff.resetAfter == 10)
    }

    /// The first lost link is made again at once, each next one after a longer wait,
    /// and a link that stayed up long enough starts the count over.
    @Test func aLostLinkIsMadeAgainAtOnceThenAfterAGrowingWait() throws {
        let links = ScriptedLinks()
        let (owner, helper) = try owner(links)
        defer { owner.stop(); helper.close() }

        links.all[0].end(.connectionLost)
        #expect(links.count == 2)
        #expect(links.all[1].isStarted)

        var ended = Date()
        links.all[1].end(.connectionLost)
        Thread.sleep(forTimeInterval: 0.15)
        #expect(links.count == 2)
        #expect(waitUntil { links.count == 3 })
        #expect(Date().timeIntervalSince(ended) >= 0.28)

        ended = Date()
        links.all[2].end(.connectionLost)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(links.count == 3)
        #expect(waitUntil { links.count == 4 })
        #expect(Date().timeIntervalSince(ended) >= 0.58)

        // Up for ten seconds: the next loss is retried at once again.
        links.advance(10)
        links.all[3].end(.connectionLost)
        #expect(links.count == 5)
        #expect(owner.linkCount == 5)
    }

    /// The terminal ending is not a reason to connect again, and neither is a
    /// refusal, which cannot happen between two halves of one app.
    @Test func anEndedSessionOrARefusalIsNotReconnected() throws {
        for reason in [TerminalEndReason.sessionEnded, .serverTooOld,
                       .refused(code: "protocol", message: "newer")] {
            let links = ScriptedLinks()
            let (owner, helper) = try owner(links)
            defer { owner.stop(); helper.close() }
            links.all[0].end(reason)
            Thread.sleep(forTimeInterval: 0.2)
            #expect(links.count == 1)
        }
    }

    /// A stop ends every retry, including one that is waiting.
    @Test func noRetryOutlivesAStop() throws {
        let links = ScriptedLinks()
        let (owner, helper) = try owner(links)
        defer { helper.close() }
        links.all[0].end(.connectionLost)
        links.all[1].end(.connectionLost)
        owner.stop()
        Thread.sleep(forTimeInterval: 0.5)
        #expect(links.count == 2)
        #expect(FileManager.default.fileExists(atPath: owner.bridge.helperSocketPath) == false)
    }

    /// The helper going away is the surface going away: the bridge stops, and its
    /// socket file goes with it.
    @Test func theHelperGoingAwayStopsTheBridge() throws {
        let links = ScriptedLinks()
        let (owner, helper) = try owner(links)
        defer { owner.stop() }
        let path = owner.bridge.helperSocketPath
        helper.close()
        #expect(waitUntil { !FileManager.default.fileExists(atPath: path) })
        #expect(owner.bridge.listeningDescriptor == -1)
    }
}

// MARK: The helper's command

/// The command a surface runs is the helper, told its bridge's socket, as exactly
/// one executable and one argument however the paths are spelled. libghostty runs it
/// through a shell (`bash -c "exec -l <command>"` under `login`, measured), so that
/// and a plain `/bin/sh` are both tried.
@Suite struct PaneBridgeCommandTests {
    @Test func theCommandNamesOneExecutableAndOneArgument() throws {
        let directory = TestScratch.root.appendingPathComponent("with space's \(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("argv")
        let script = directory.appendingPathComponent("wietty pty's helper")
        try """
        #!/bin/sh
        {
          printf '%s\\n' "$#"
          for argument in "$@"; do printf '[%s]\\n' "$argument"; done
        } > "\(record.path)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let socket = "/tmp/a b'c $HOME `x`.sock"
        let command = PaneBridges.command(helper: script.path, socket: socket)

        for (shell, arguments) in [("/bin/sh", ["-c", "exec " + command]),
                                   ("/bin/bash", ["--noprofile", "--norc", "-c", "exec -l " + command])] {
            try? FileManager.default.removeItem(at: record)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(shell)")
            let recorded = try String(contentsOf: record, encoding: .utf8)
            #expect(recorded == "1\n[\(socket)]\n", "\(shell)")
        }
    }
}
