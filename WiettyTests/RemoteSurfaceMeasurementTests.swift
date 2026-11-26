import AppKit
import Darwin
import Foundation
import Testing
import WiettyCore
@testable import WiettyShared
@testable import Wietty

/// Measurements for phase 3 step 5 of issue #84, a terminal on another Mac shown in a
/// libghostty surface: the surface's `wietty-pty` connects to a `TerminalBridge`, whose
/// link wraps the package's `TerminalStreamConnection` over a WebSocket to a
/// `RemoteServer`, and the surface is made on every show and destroyed on every hide.
///
/// A measurement, not a test: it asserts only what it needs to stay meaningful, and
/// prints lines starting with `STEP5`. Every measurement runs three times.
///
/// - R1: a snapshot (hard reset, history, screen, modes) fed through the real bridge and
///   helper to a real surface left dirty by its child, compared with the same snapshot
///   on a clean surface and with the libghostty-vt model that produced it.
/// - R2: a real `RemoteServer` on 127.0.0.1 flooding one `TerminalStreamConnection`
///   whose callback is fast, slow (50 ms per message) or stalled: this process's
///   memory, the sockets' queues and the server's resyncs over time.
/// - R3: the cost of a show (surface, helper, WebSocket, snapshot) for 1,000, 10,000
///   and 100,000 lines of history, and what 100 shows and hides leave behind.
/// - R4: the largest snapshots through the helper's 4 KiB pump: the blocking write and
///   the longest gap of a main queue heartbeat meanwhile.
/// - R7: what the surface shows and does when the bridge stops after the session ended,
///   and when it is kept with no link.
/// - R8: 50 destroy and create cycles in one main turn, with an id per creation and
///   with one id reused: which late callbacks of an old surface reach the host.
///
/// **Not part of the normal suite.** It needs a window, a Metal device and minutes. It
/// runs only with `WIETTY_REMOTE_SURFACE_CHECK=1` in the test host's environment; see
/// `scripts/remote-surface-check.sh`. Like the other real window checks it builds a
/// `GhosttySurfaceHost` of its own beside the app's, which takes the host callbacks over
/// for the run. The throwaway links below live in the test target only.
@MainActor
@Suite(.enabled(if: RemoteSurfaceCheck.isRequested), .serialized)
struct RemoteSurfaceMeasurementTests {
    nonisolated static let runs = 3

    // MARK: R1. A snapshot on a dirty surface

    @Test func r1ASnapshotOnADirtySurface() async throws {
        let rig = try await SurfaceRig.make(width: 1000, height: 700, container: false)
        defer { rig.close() }
        for run in 1...Self.runs {
            for variant in R1Variant.allCases {
                var results: [R1Result] = []
                for dirty in [false, true] {
                    results.append(try await r1(rig, run: run, variant: variant, dirty: dirty))
                }
                let clean = results[0], dirty = results[1]
                let same = clean.answers == dirty.answers && clean.keys == dirty.keys
                    && clean.whole == dirty.whole && clean.viewport == dirty.viewport
                report("""
                    STEP5 R1 run=\(run) model=\(variant.rawValue) compare clean-vs-dirty \
                    identical=\(same ? "yes" : "NO") answers=\(clean.answers == dirty.answers ? "same" : "DIFF") \
                    keys=\(clean.keys == dirty.keys ? "same" : "DIFF") \
                    history=\(clean.whole == dirty.whole ? "same" : "DIFF") \
                    viewport=\(clean.viewport == dirty.viewport ? "same" : "DIFF")
                    """)
                #expect(same)
            }
        }
    }

    enum R1Variant: String, CaseIterable {
        /// The model on its primary screen with history, every mode at its default.
        case plain
        /// The same with modes a snapshot must set again after its reset: mouse (1000,
        /// 1006), bracketed paste, application cursor keys, kitty flags 1 and a
        /// scrolling region.
        case modes
    }

    struct R1Result {
        let answers: String
        let keys: String
        let whole: [String]
        let viewport: [String]
    }

    /// The modes asked with DECRQM after every state change.
    static let r1Modes: [Int] = [1049, 1000, 1002, 1003, 1006, 2004, 1, 6, 25, 7]

    /// The queries: DECRQM per mode, the kitty flags, DECRQSS for the scrolling region,
    /// the cursor style and the pen, the cursor position, and a status report last,
    /// whose answer says every answer before it has been written.
    static var r1Queries: [UInt8] {
        var text = ""
        for mode in r1Modes { text += "\u{1B}[?\(mode)$p" }
        text += "\u{1B}[?u"
        text += "\u{1B}P$qr\u{1B}\\"
        text += "\u{1B}P$q q\u{1B}\\"
        text += "\u{1B}P$qm\u{1B}\\"
        text += "\u{1B}[6n"
        text += "\u{1B}[5n"
        return Array(text.utf8)
    }

    /// What a child leaves behind: 600 lines of history, the alternate screen with text
    /// on it, mouse reporting (1000, 1002, 1006), bracketed paste, application cursor
    /// keys and keypad, kitty flags 5 pushed, a blinking bar cursor, a scrolling region,
    /// origin mode, a coloured pen, a hidden cursor and the cursor moved.
    static var r1History: [UInt8] {
        var text = ""
        for n in 0..<600 { text += "OLD-HIST \(n) the dirty child's own history\r\n" }
        return Array(text.utf8)
    }

    static var r1Dirt: [UInt8] {
        var text = ""
        text += "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
        for n in 0..<10 { text += "OLD-ALT \(n) full screen program\r\n" }
        text += "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h"
        text += "\u{1B}[?2004h"
        text += "\u{1B}[?1h\u{1B}="
        text += "\u{1B}[>5u"
        text += "\u{1B}[5 q"
        text += "\u{1B}[3;15r"
        text += "\u{1B}[?6h"
        text += "\u{1B}[1;31;44m"
        text += "\u{1B}[?25l"
        text += "\u{1B}[5;10H"
        return Array(text.utf8)
    }

    private func r1Model(_ variant: R1Variant, size: TerminalSize, graphemes: Bool) throws -> GhosttyVtTerminal {
        let model = try GhosttyVtTerminal(size: size, scrollbackLines: 10_000, graphemeClustering: graphemes)
        var text = ""
        for n in 0..<1_500 { text += "NEW-HIST \(n) from the model's own history\r\n" }
        for n in 0..<8 { text += "\u{1B}[3\(n % 7 + 1)mNEW-SCREEN \(n)\u{1B}[0m on the model's screen\r\n" }
        text += "NEW-MARKER end of the model"
        if variant == .modes {
            text += "\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?1h\u{1B}[>1u\u{1B}[3;20r"
        }
        text += "\u{1B}[7;15H"
        model.write(Array(text.utf8))
        return model
    }

    private func r1(_ rig: SurfaceRig, run: Int, variant: R1Variant, dirty: Bool) async throws -> R1Result {
        let link = ScriptedLink()
        let id = "r1-\(run)-\(variant.rawValue)-\(dirty ? "dirty" : "clean")"
        let surface = try rig.open(id: id, link: link)
        defer { surface.close() }
        #expect(await waitUntil(10) { link.started })
        let grid = try await rig.settledGrid(id)
        let model = try r1Model(variant, size: grid, graphemes: rig.host.graphemeClustering)
        let prefix = "STEP5 R1 run=\(run) model=\(variant.rawValue) surface=\(dirty ? "dirty" : "clean")"

        if dirty {
            // The history first, read back, so it is known to be in the surface's
            // scrollback before the program switches screens.
            link.deliver(.data(Self.r1History))
            link.deliver(.data(Array("\u{1B}[5n".utf8)))
            _ = try await answers(link)
            let history = rig.host.readText(id: id, maxLines: 1_000_000) ?? []
            report("""
                \(prefix) history-before-dirt surfaceLines=\(normalised(history).count) \
                oldHistLines=\(history.filter { $0.hasPrefix("OLD-HIST ") }.count)
                """)
            link.deliver(.data(Self.r1Dirt))
            link.deliver(.data(Self.r1Queries))
            let control = try await answers(link)
            let keys = try await probeInput(rig, id: id, link: link)
            let text = rig.host.readText(id: id, maxLines: 1_000_000) ?? []
            report("""
                \(prefix) before-snapshot answers=\(escaped(control)) keys=\(keys) \
                surfaceLines=\(normalised(text).count) oldLines=\(text.filter { $0.contains("OLD-") }.count)
                """)
        }

        let frame = model.snapshotFrame()
        let snapshot = TerminalPaint.hardReset + frame.bytes
        link.deliver(.resize(cols: frame.size.cols, rows: frame.size.rows, own: false))
        link.deliver(.snapshot(snapshot))
        link.deliver(.data(Self.r1Queries))
        let after = try await answers(link)
        let viewport = normalised(rig.host.readText(id: id, maxLines: grid.rows) ?? [])
        let modelViewport = normalised(model.viewportLines(unwrap: true))
        let whole = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? [])
        let modelWhole = normalised(model.text(maxLines: 1_000_000).components(separatedBy: "\n"))
        let old = whole.filter { $0.contains("OLD-") }.count
        let newHistory = whole.filter { $0.hasPrefix("NEW-HIST ") }.count
        let modelHistory = modelWhole.filter { $0.hasPrefix("NEW-HIST ") }.count

        // What the model says the answers must be.
        var expected = ""
        for mode in Self.r1Modes { expected += "\u{1B}[?\(mode);\(model.isModeSet(UInt16(mode)) ? 1 : 2)$y" }
        expected += "\u{1B}[?\(model.kittyKeyboardFlags)u"
        let cursor = model.cursor
        let cpr = "\u{1B}[\(cursor.y + 1);\(cursor.x + 1)R"
        let modesMatch = after.hasPrefix(expected)
        let cursorMatch = after.contains(cpr)
        let keys = try await probeInput(rig, id: id, link: link)
        report("""
            \(prefix) after-snapshot grid=\(grid.cols)x\(grid.rows) snapshotBytes=\(snapshot.count) \
            viewportMatchesModel=\(viewport == modelViewport ? "yes" : "NO") \
            historyMatchesModel=\(whole == modelWhole ? "yes" : "NO") surfaceLines=\(whole.count) \
            modelLines=\(modelWhole.count) newHistLines=\(newHistory)/\(modelHistory) oldLines=\(old) \
            modelScrollbackRows=\(model.scrollbackRows) modesMatchModel=\(modesMatch ? "yes" : "NO") \
            cursorMatchesModel=\(cursorMatch ? "yes" : "NO") modelCursor=\(cursor.y + 1);\(cursor.x + 1)
            """)
        report("\(prefix) after-snapshot answers=\(escaped(after)) expectedPrefix=\(escaped(expected)) keys=\(keys)")
        if whole != modelWhole { report("\(prefix) first difference: \(firstDifference(whole, modelWhole))") }
        if viewport != modelViewport { report("\(prefix) viewport difference: \(firstDifference(viewport, modelViewport))") }
        #expect(old == 0)
        #expect(whole == modelWhole)
        #expect(viewport == modelViewport)
        #expect(modesMatch && cursorMatch)
        return R1Result(answers: after, keys: keys, whole: whole, viewport: viewport)
    }

    /// Everything the surface answered up to and including the status report, which the
    /// queries end with, then cleared.
    private func answers(_ link: ScriptedLink) async throws -> String {
        let done = await waitUntil(10) { String(decoding: link.sentSoFar, as: UTF8.self).contains("\u{1B}[0n") }
        #expect(done, "no answer to the status report")
        return String(decoding: link.takeSent(), as: UTF8.self)
    }

    /// Escape, up arrow and a click in the middle, each pressed and released, and what
    /// reached the link for each.
    private func probeInput(_ rig: SurfaceRig, id: String, link: ScriptedLink) async throws -> String {
        guard let view = rig.host.view(id: id) as? GhosttySurfaceView else { return "noview" }
        _ = link.takeSent()
        var parts: [String] = []
        let window = rig.window
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> (NSEvent, NSEvent) {
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            return (down, up)
        }
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        for (name, code, characters, flags) in [("esc", UInt16(53), "\u{1B}", NSEvent.ModifierFlags()),
                                                ("up", UInt16(126), up, NSEvent.ModifierFlags([.function, .numericPad]))] {
            let (down, release) = key(code, characters, flags)
            view.keyDown(with: down)
            view.keyUp(with: release)
            _ = await waitUntil(0.4) { !link.sentSoFar.isEmpty }
            try await Task.sleep(for: .milliseconds(100))
            parts.append("\(name)=\(escaped(String(decoding: link.takeSent(), as: UTF8.self)))")
        }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        _ = await waitUntil(0.4) { !link.sentSoFar.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        parts.append("click=\(escaped(String(decoding: link.takeSent(), as: UTF8.self)))")
        return parts.joined(separator: ",")
    }

    // MARK: R2. Backpressure through URLSessionWebSocketTask

    enum R2Client: String, CaseIterable {
        case fast, slow50ms, stalled
    }

    @Test func r2BackpressureThroughURLSession() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let port = server.port, token = server.token, rig = server.rig
        try await offMain {
            for run in 1...Self.runs {
                for client in R2Client.allCases {
                    try Self.flood(rig: rig, port: port, token: token, run: run, client: client)
                }
            }
        }
    }

    /// Floods one session at 16 MiB/s for 15 seconds while one client reads it, then
    /// 5 seconds quiet; samples once a second.
    private nonisolated static func flood(rig: StreamRig, port: Int, token: String, run: Int,
                                          client: R2Client) throws {
        let session = "r2-\(client.rawValue)-\(run)"
        try rig.add(session, cols: 120, rows: 34, scrollback: TerminalScrollback.defaultLines)
        rig.fill(session, lines: TerminalScrollback.defaultLines + 200)
        defer { rig.end(session) }
        let counts = ClientCounts()
        let release = DispatchSemaphore(value: 0)
        let connection = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "step5", host: "127.0.0.1", port: port, token: token),
            sessionId: session, resize: .reflow, callbackQueue: DispatchQueue(label: "step5.r2.client"))
        connection.onMessage = { message in
            counts.received(message)
            switch client {
            case .fast: break
            case .slow50ms: usleep(50_000)
            case .stalled:
                if case .data = message, counts.firstData() { _ = release.wait(timeout: .now() + 30) }
            }
        }
        connection.onEnded = { reason in counts.ended(reason) }
        let before = processMemory()
        connection.start()
        defer { connection.stop() }
        guard waitUntil(within: 10, { counts.snapshots >= 1 }) else {
            report("STEP5 R2 run=\(run) client=\(client.rawValue) no snapshot")
            return
        }
        let start = now()
        let feeder = PacedFeeder(rig: rig, session: session, bytesPerSecond: 16 << 20)
        var peakResident: UInt64 = 0, peakFootprint: UInt64 = 0
        var peakRecvQ = 0, peakSendQ = 0
        for second in 1...20 {
            Thread.sleep(until: Date(timeIntervalSinceNow: 1))
            if second == 15 { feeder.stop() }
            if client == .stalled && second == 17 { release.signal() }
            let memory = processMemory()
            let queues = tcpQueues(port: port)
            peakResident = max(peakResident, memory.resident)
            peakFootprint = max(peakFootprint, memory.footprint)
            peakRecvQ = max(peakRecvQ, queues.clientRecvQ)
            peakSendQ = max(peakSendQ, queues.serverSendQ)
            report("""
                STEP5 R2 run=\(run) client=\(client.rawValue) t=\(second)s fedMiB=\(mib(feeder.fed)) \
                residentMiB=\(mib(memory.resident)) footprintMiB=\(mib(memory.footprint)) \
                deltaResidentMiB=\(signedMiB(memory.resident, before.resident)) \
                clientMessages=\(counts.messages) clientDataMiB=\(mib(counts.dataBytes)) \
                clientSnapshots=\(counts.snapshots) serverSnapshots=\(rig.snapshots(of: session)) \
                clientRecvQ=\(queues.clientRecvQ) serverSendQ=\(queues.serverSendQ) end=\(counts.endText)
                """)
        }
        feeder.stop()
        report("""
            STEP5 R2 run=\(run) client=\(client.rawValue) summary seconds=\(String(format: "%.1f", Double(now() - start) / 1e9)) \
            fedMiB=\(mib(feeder.fed)) clientDataMiB=\(mib(counts.dataBytes)) \
            resyncs=\(max(0, rig.snapshots(of: session) - 1)) clientSnapshots=\(counts.snapshots) \
            residentBeforeMiB=\(mib(before.resident)) peakResidentMiB=\(mib(peakResident)) \
            peakFootprintMiB=\(mib(peakFootprint)) footprintBeforeMiB=\(mib(before.footprint)) \
            peakClientRecvQ=\(peakRecvQ) peakServerSendQ=\(peakSendQ) end=\(counts.endText)
            """)
    }

    // MARK: R3 and R4. The cost of a show, and large snapshots

    struct ShowCase {
        let label: String
        let lines: Int
        let scrollback: Int
        let dense: Bool
    }

    static let showCases = [
        ShowCase(label: "hist1k", lines: 1_200, scrollback: 1_000, dense: false),
        ShowCase(label: "hist10k", lines: 10_200, scrollback: 10_000, dense: false),
        ShowCase(label: "hist100k", lines: 100_200, scrollback: 100_000, dense: false),
        ShowCase(label: "dense100k", lines: 100_200, scrollback: 100_000, dense: true),
    ]

    @Test func r3AndR4TheCostOfAShow() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        for item in Self.showCases {
            try server.rig.add(item.label, cols: 120, rows: 34, scrollback: item.scrollback)
            server.rig.fill(item.label, lines: item.lines, dense: item.dense)
            server.rig.write(item.label, Array("\r\nSTEP5-END \(item.label)".utf8))
        }
        let heartbeat = Heartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        for run in 1...Self.runs {
            for item in Self.showCases {
                try await show(rig, server: server, item: item, run: run, heartbeat: heartbeat)
            }
        }
    }

    private func show(_ rig: SurfaceRig, server: ServerRig, item: ShowCase, run: Int,
                      heartbeat: Heartbeat) async throws {
        let id = "r3-\(item.label)-\(run)"
        let marker = "STEP5-END \(item.label)"
        let start = now()
        let link = WebSocketLink(port: server.port, token: server.token, session: item.label)
        let surface = try rig.open(id: id, link: link, imposeOnResize: true)
        defer { surface.close() }
        let created = now()
        let visible = await waitUntil(60, poll: .milliseconds(2)) {
            (rig.host.readText(id: id, maxLines: 34) ?? []).contains { $0.contains(marker) }
        }
        let shown = now()
        let probe = link.probe
        let grid = rig.events.firstGrid[id]
        let received = probe.snapshotReceivedAt ?? 0, written = probe.snapshotWrittenAt ?? 0
        let gap = heartbeat.maxGap(from: received, to: shown)
        let gapWrite = heartbeat.maxGap(from: received, to: written)
        // The whole screen read is slow on a deep scrollback; after the timing.
        let kept = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? []).count
        report("""
            STEP5 R3 run=\(run) hist=\(item.label) visible=\(visible ? "yes" : "NO") \
            snapshotBytes=\(probe.snapshotBytes) createMs=\(ms(created &- start)) \
            toFirstGridMs=\(grid.map { ms($0 &- start) } ?? "none") \
            toHelperConnectedMs=\(probe.startedAt.map { ms($0 &- start) } ?? "none") \
            toFirstMessageMs=\(probe.firstMessageAt.map { ms($0 &- start) } ?? "none") \
            toSnapshotReceivedMs=\(ms(received &- start)) toSnapshotWrittenMs=\(ms(written &- start)) \
            toVisibleMs=\(ms(shown &- start)) surfaceLinesKept=\(kept)
            """)
        report("""
            STEP5 R4 run=\(run) hist=\(item.label) snapshotBytes=\(probe.snapshotBytes) \
            blockingWriteMs=\(ms(written &- received)) \
            writeMiBps=\(String(format: "%.1f", Double(probe.snapshotBytes) / 1_048_576 / max(1e-9, Double(written &- received) / 1e9))) \
            writtenToVisibleMs=\(ms(shown &- written)) mainGapDuringWriteMs=\(ms(gapWrite)) \
            mainGapUntilVisibleMs=\(ms(gap)) heartbeatMaxRunMs=\(ms(heartbeat.maxGap(from: start, to: shown)))
            """)
        #expect(visible)
        // The hide, timed: the bridge stopped and the surface freed, on the main actor.
        let hideStart = now()
        surface.close()
        let hidden = now()
        try await Task.sleep(for: .milliseconds(200))
        report("""
            STEP5 R3-HIDE run=\(run) hist=\(item.label) hideMs=\(ms(hidden &- hideStart)) \
            mainGapDuringHideMs=\(ms(heartbeat.maxGap(from: hideStart, to: hidden)))
            """)
    }

    @Test func r3HundredShowsAndHides() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        let session = "cycles"
        try server.rig.add(session, cols: 120, rows: 34, scrollback: 1_000)
        server.rig.fill(session, lines: 1_200)
        server.rig.write(session, Array("\r\nSTEP5-END cycles".utf8))
        // One show first, so what is created once per process (the renderer's caches,
        // URLSession, the helper's image in the page cache) is not counted as a leak.
        try await cycle(rig, server: server, session: session, id: "r3-warm")
        try await Task.sleep(for: .seconds(3))
        for run in 1...Self.runs {
            let before = Census.take()
            var times: [UInt64] = []
            var failures = 0
            for index in 0..<100 {
                let start = now()
                let shown = try await cycle(rig, server: server, session: session, id: "r3-\(run)-\(index)")
                if !shown { failures += 1 }
                times.append(now() &- start)
                if index == 49 {
                    let middle = Census.take()
                    report("STEP5 R3-CYCLES run=\(run) after=50 \(middle.describe(against: before))")
                }
            }
            let immediately = Census.take()
            try await Task.sleep(for: .seconds(3))
            let settled = Census.take()
            report("STEP5 R3-CYCLES run=\(run) after=100 immediately \(immediately.describe(against: before))")
            report("""
                STEP5 R3-CYCLES run=\(run) after=100 settled3s \(settled.describe(against: before)) \
                failures=\(failures) cycle \(summary(times))
                """)
        }
    }

    /// Show then hide: true when the snapshot became visible.
    private func cycle(_ rig: SurfaceRig, server: ServerRig, session: String, id: String) async throws -> Bool {
        let link = WebSocketLink(port: server.port, token: server.token, session: session)
        let surface = try rig.open(id: id, link: link, imposeOnResize: true)
        defer { surface.close() }
        return await waitUntil(10, poll: .milliseconds(2)) {
            (rig.host.readText(id: id, maxLines: 34) ?? []).contains { $0.contains("STEP5-END") }
        }
    }

    // MARK: R7. Ends that leave the helper

    @Test func r7EndsThatLeaveTheHelper() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        for run in 1...Self.runs {
            for keep in [false, true] {
                try await r7(rig, server: server, run: run, keepBridge: keep)
            }
        }
    }

    private func r7(_ rig: SurfaceRig, server: ServerRig, run: Int, keepBridge: Bool) async throws {
        let session = "r7-\(run)-\(keepBridge ? "kept" : "stopped")"
        try server.rig.add(session, cols: 100, rows: 30, scrollback: 1_000)
        server.rig.fill(session, lines: 200)
        server.rig.write(session, Array("\r\nSTEP5-END last screen of \(session)".utf8))
        let prefix = "STEP5 R7 run=\(run) bridge=\(keepBridge ? "kept-no-link" : "stopped-on-ended")"
        let before = Census.take()
        let link = WebSocketLink(port: server.port, token: server.token, session: session)
        let id = "r7-\(run)-\(keepBridge)"
        let surface = try rig.open(id: id, link: link, imposeOnResize: true)
        defer { surface.close() }
        let ended = EndBox()
        let bridge = surface.bridge
        surface.bridge.onEnded = { reason in
            ended.set(reason)
            // As `OwnPaneBridge` does on `.sessionEnded`: off the callback.
            if !keepBridge { DispatchQueue.global().async { bridge.stop() } }
        }
        #expect(await waitUntil(10) {
            (rig.host.readText(id: id, maxLines: 30) ?? []).contains { $0.contains("STEP5-END") }
        })
        let shown = Census.take()
        server.rig.end(session)
        _ = await waitUntil(5) { ended.reason != nil }
        try await Task.sleep(for: .seconds(2))
        let screen = lastLines(rig.host.readText(id: id, maxLines: 30) ?? [], 3)
        let afterEnd = Census.take()
        report("""
            \(prefix) end=\(ended.text) closeRequests=\(rig.events.closes(id)) \
            lastLines=\(screen) surfaceGrid=\(rig.host.size(id: id).map { "\($0.cols)x\($0.rows)" } ?? "none") \
            shown[\(shown.describe(against: before))] afterEnd2s[\(afterEnd.describe(against: before))]
            """)
        if let view = rig.host.view(id: id) as? GhosttySurfaceView {
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: rig.window.windowNumber, context: nil, characters: "a",
                                        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            view.keyDown(with: down)
        }
        try await Task.sleep(for: .seconds(1))
        let afterKey = Census.take()
        report("""
            \(prefix) after-key closeRequests=\(rig.events.closes(id)) \
            lastLines=\(lastLines(rig.host.readText(id: id, maxLines: 30) ?? [], 3)) \
            surfaceExists=\(rig.host.view(id: id) != nil) afterKey[\(afterKey.describe(against: before))]
            """)
        surface.close()
        try await Task.sleep(for: .seconds(2))
        report("\(prefix) after-hide2s[\(Census.take().describe(against: before))]")
    }

    // MARK: R8. Fast hide and show

    @Test func r8FastHideAndShow() async throws {
        let rig = try await SurfaceRig.make(width: 1000, height: 700, container: true)
        defer { rig.close() }
        for run in 1...Self.runs {
            for reuse in [false, true] {
                try await r8(rig, run: run, reuseId: reuse)
            }
        }
    }

    private func r8(_ rig: SurfaceRig, run: Int, reuseId: Bool) async throws {
        let prefix = "STEP5 R8 run=\(run) ids=\(reuseId ? "one-reused" : "one-per-creation")"
        let before = Census.take()
        rig.events.reset()
        func idFor(_ generation: Int) -> String { reuseId ? "r8-\(run)-same" : "r8-\(run)-\(generation)" }
        func open(_ generation: Int) throws -> OpenSurface {
            let link = ScriptedLink()
            // As a remote program would: a title every 2 ms and a bell every 20 ms,
            // each naming the generation that sent it.
            link.generate(everyMilliseconds: 2) { tick in
                let bell = tick % 10 == 0 ? "\u{07}" : ""
                return .data(Array("\u{1B}]2;g\(generation)-\(tick)\u{07}\(bell)line \(tick)\r\n".utf8))
            }
            return try rig.open(id: idFor(generation), link: link, imposeOnResize: false)
        }
        var current = try open(0)
        var destroyed: [(id: String, generation: Int, at: UInt64)] = []
        var generationSince: [UInt64] = [now()]
        func handle(_ id: String) -> UInt {
            (rig.host.view(id: id) as? GhosttySurfaceView)?.surfaceHandle.map { UInt(bitPattern: $0) } ?? 0
        }
        var handles: [UInt] = [handle(idFor(0))]
        let cycles = 50
        for generation in 1...cycles {
            // Live: a grid reported and a title of this generation seen.
            let liveId = idFor(generation - 1)
            _ = await waitUntil(2) {
                rig.events.titles.contains { $0.id == liveId && $0.title.hasPrefix("g\(generation - 1)-") }
            }
            // One main turn: hide (bridge first, as the host does), then show.
            current.close()
            destroyed.append((liveId, generation - 1, now()))
            current = try open(generation)
            generationSince.append(now())
            handles.append(handle(idFor(generation)))
        }
        _ = await waitUntil(2) {
            rig.events.titles.contains { $0.id == idFor(cycles) && $0.title.hasPrefix("g\(cycles)-") }
        }
        try await Task.sleep(for: .milliseconds(500))
        current.close()
        destroyed.append((idFor(cycles), cycles, now()))
        try await Task.sleep(for: .seconds(2))

        // Late: an event naming a destroyed id after its destruction, for an id that no
        // surface had again. Cross talk: an event of an older generation delivered while
        // a newer surface had the id.
        var late = 0, crossTitles = 0, crossCloses = 0
        let events = rig.events
        for entry in destroyed where !reuseId {
            late += events.all.filter { $0.id == entry.id && $0.at > entry.at }.count
        }
        func generationAt(_ time: UInt64) -> Int { generationSince.lastIndex { $0 <= time } ?? 0 }
        var foreign: [String] = []
        var crossSamples: [String] = []
        var crossOnReusedAddress = 0
        for title in events.titles {
            guard title.title.hasPrefix("g"), let sent = Int(title.title.dropFirst().prefix { $0 != "-" }) else {
                foreign.append("\(title.id)=\(title.title.debugDescription)")
                continue
            }
            if reuseId, sent < generationAt(title.at) { crossTitles += 1 }
            if !reuseId, title.id != idFor(sent) {
                crossTitles += 1
                let receiver = destroyed.firstIndex { $0.id == title.id } ?? cycles
                let reused = receiver > 0 && sent < handles.count && handles[sent] == handles[receiver]
                if reused { crossOnReusedAddress += 1 }
                if crossSamples.count < 6 {
                    let age = (Int64(title.at) - Int64(generationSince[receiver])) / 1_000_000
                    crossSamples.append("\(title.id)<-\(title.title)(msAfterCreation=\(age),sameHandleAsSender=\(reused))")
                }
            }
            if reuseId, sent < generationAt(title.at), crossSamples.count < 6 {
                crossSamples.append("\(title.id)<-\(title.title)(gen now \(generationAt(title.at)))")
            }
        }
        let reusedHandles = (1..<handles.count).filter { handles[$0] == handles[$0 - 1] }.count
        report("""
            \(prefix) crossSamples=\(crossSamples.joined(separator: ",")) \
            creationsOnThePreviousSurfacesAddress=\(reusedHandles)/\(handles.count - 1) \
            crossTitlesOnAReusedAddress=\(crossOnReusedAddress)
            """)
        report("\(prefix) titlesNotFromTheStream=\(foreign.count) samples=\(foreign.prefix(4).joined(separator: ","))")
        if reuseId {
            // Every close request while a surface had the id is an old helper's.
            crossCloses = events.all.filter { $0.kind == "close" && generationAt($0.at) <= cycles
                && $0.at < (destroyed.last?.at ?? 0) }.count
        }
        let kinds = Dictionary(grouping: events.all, by: \.kind).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        report("""
            \(prefix) cycles=\(cycles) events[\(kinds)] lateForDestroyedIds=\(late) \
            crossTitles=\(crossTitles) crossCloseRequests=\(crossCloses) \
            after2s[\(Census.take().describe(against: before))]
            """)
    }
}

// MARK: - Gate

/// Outside the suite, because a suite's own traits cannot refer to its members.
enum RemoteSurfaceCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_REMOTE_SURFACE_CHECK"] == "1"
    }
}

// MARK: - Surfaces

/// A host of its own, one window, and surfaces opened on it with a bridge each.
@MainActor
private final class SurfaceRig {
    let host: GhosttySurfaceHost
    let window: NSWindow
    let container: SurfaceContainerView?
    let events: HostEvents
    let directory: URL
    let helper: String
    private static var sequence = 70_000

    private init(host: GhosttySurfaceHost, window: NSWindow, container: SurfaceContainerView?,
                 events: HostEvents, directory: URL, helper: String) {
        self.host = host
        self.window = window
        self.container = container
        self.events = events
        self.directory = directory
        self.helper = helper
    }

    static func make(width: CGFloat, height: CGFloat, container wantsContainer: Bool) async throws -> SurfaceRig {
        let directory = TestScratch.root.appendingPathComponent("wietty-step5-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = try GhosttySurfaceHost()
        let events = HostEvents()
        events.attach(to: host)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var container: SurfaceContainerView?
        if wantsContainer, let content = window.contentView {
            let view = SurfaceContainerView()
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            container = view
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        report("STEP5-ENV libghostty \(GhosttySurfaceHost.libraryVersion()) scale \(window.backingScaleFactor) pid \(getpid())")
        return SurfaceRig(host: host, window: window, container: container, events: events,
                          directory: directory, helper: try bundledHelperURL().path)
    }

    /// A bridge for `link` and a surface running the helper pointed at it, shown in the
    /// window. With `imposeOnResize` the server's grid is imposed on the surface, as the
    /// pane would.
    func open(id: String, link: any TerminalStreamLink, imposeOnResize: Bool = false) throws -> OpenSurface {
        Self.sequence += 1
        let path = try LocalSocketPaths.bridge(Self.sequence)
        let bridge = try TerminalBridge(helperSocketPath: path, link: link)
        if imposeOnResize {
            let host = self.host
            bridge.onResize = { cols, rows, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { host.impose(grid: TerminalSize(cols: cols, rows: rows), on: id) }
                }
            }
        }
        do {
            try host.createSurface(id: id, command: PaneBridges.command(helper: helper, socket: path),
                                   directory: directory, title: nil)
        } catch {
            bridge.stop()
            throw error
        }
        let view = host.view(id: id)!
        if let container {
            SurfaceContainer.attach(view, to: container)
            window.contentView?.layoutSubtreeIfNeeded()
        } else {
            view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            window.contentView?.addSubview(view)
            window.makeFirstResponder(view)
        }
        return OpenSurface(host: host, id: id, bridge: bridge)
    }

    /// The surface's grid once it has not moved for 300 ms.
    func settledGrid(_ id: String) async throws -> TerminalSize {
        var last: TerminalSize?
        var since = now()
        let deadline = now() + 20_000_000_000
        while now() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            let grid = host.size(id: id)
            if grid != last { last = grid; since = now() } else if let grid, now() - since > 300_000_000 { return grid }
        }
        throw Step5Error.neverSettled
    }

    func close() {
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// One shown surface. `close` hides it: the bridge first, then the surface, as
/// `GhosttySurfaceHost.destroySurface` does with the bridges it owns.
@MainActor
private final class OpenSurface {
    let host: GhosttySurfaceHost
    let id: String
    let bridge: TerminalBridge
    private var closed = false

    init(host: GhosttySurfaceHost, id: String, bridge: TerminalBridge) {
        self.host = host
        self.id = id
        self.bridge = bridge
    }

    func close() {
        guard !closed else { return }
        closed = true
        bridge.stop()
        host.destroySurface(id: id)
    }
}

/// Every host callback, with the time it arrived.
@MainActor
private final class HostEvents {
    struct Event {
        let at: UInt64
        let kind: String
        let id: String
    }

    private(set) var all: [Event] = []
    private(set) var titles: [(at: UInt64, id: String, title: String)] = []
    private(set) var firstGrid: [String: UInt64] = [:]

    func attach(to host: GhosttySurfaceHost) {
        host.onTitle = { [weak self] id, title in
            self?.record("title", id)
            self?.titles.append((now(), id, title))
        }
        host.onBell = { [weak self] id in self?.record("bell", id) }
        host.onDesktopNotification = { [weak self] id, _, _ in self?.record("notification", id) }
        host.onResized = { [weak self] id, _ in
            self?.record("grid", id)
            if self?.firstGrid[id] == nil { self?.firstGrid[id] = now() }
        }
        host.onMetricsChanged = { [weak self] id in self?.record("metrics", id) }
        host.onCloseRequested = { [weak self] id in self?.record("close", id) }
        host.onInput = { [weak self] id in self?.record("input", id) }
    }

    private func record(_ kind: String, _ id: String) {
        all.append(Event(at: now(), kind: kind, id: id))
    }

    func closes(_ id: String) -> Int { all.filter { $0.kind == "close" && $0.id == id }.count }

    func reset() {
        all = []
        titles = []
    }
}

// MARK: - Links

/// An in-process link: what it is told to deliver, on a serial queue of its own, and
/// every byte the bridge sends it recorded.
private final class ScriptedLink: TerminalStreamLink, @unchecked Sendable {
    private nonisolated(unsafe) static let key = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "step5.scripted-link")
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var isStarted = false
    private var isStopped = false
    private var sent: [UInt8] = []
    private var timer: DispatchSourceTimer?

    init() { queue.setSpecific(key: Self.key, value: 1) }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }

    var started: Bool { lock.withLock { isStarted } }
    var sentSoFar: [UInt8] { lock.withLock { sent } }

    func start() {
        let source: DispatchSourceTimer? = lock.withLock {
            isStarted = true
            return timer
        }
        source?.resume()
    }

    func stop() {
        let (source, wasStarted): (DispatchSourceTimer?, Bool) = lock.withLock {
            isStopped = true
            let source = timer
            timer = nil
            return (source, isStarted)
        }
        // A source never resumed must be resumed before it goes, or libdispatch traps.
        if !wasStarted { source?.resume() }
        source?.cancel()
        if DispatchQueue.getSpecific(key: Self.key) == nil { queue.sync {} }
    }

    func send(_ bytes: [UInt8]) {
        lock.withLock { if isStarted && !isStopped { sent += bytes } }
    }

    func claim(cols: Int, rows: Int) {}

    func takeSent() -> [UInt8] {
        lock.withLock {
            let taken = sent
            sent = []
            return taken
        }
    }

    func deliver(_ message: StreamMessage) {
        queue.async { [self] in
            let handler = lock.withLock { isStopped ? nil : messageHandler }
            handler?(message)
        }
    }

    func end(_ reason: TerminalEndReason) {
        queue.async { [self] in
            let handler = lock.withLock { isStopped ? nil : endHandler }
            handler?(reason)
        }
    }

    /// Delivers `make(tick)` every `milliseconds` from `start()` until `stop()`.
    func generate(everyMilliseconds milliseconds: Int, _ make: @escaping @Sendable (Int) -> StreamMessage) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(milliseconds))
        let tick = Counter()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let handler = self.lock.withLock { self.isStopped ? nil : self.messageHandler }
            handler?(make(tick.next()))
        }
        lock.withLock { timer = source }
    }
}

/// When each step of a link's life happened.
private final class LinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: UInt64?
    private var first: UInt64?
    private var snapshotIn: UInt64?
    private var snapshotOut: UInt64?
    private var size = 0

    var startedAt: UInt64? { lock.withLock { started } }
    var firstMessageAt: UInt64? { lock.withLock { first } }
    var snapshotReceivedAt: UInt64? { lock.withLock { snapshotIn } }
    var snapshotWrittenAt: UInt64? { lock.withLock { snapshotOut } }
    var snapshotBytes: Int { lock.withLock { size } }

    func markStarted() { lock.withLock { if started == nil { started = now() } } }
    func markHello() { lock.withLock { if first == nil { first = now() } } }

    func handled(_ message: StreamMessage, from start: UInt64, to end: UInt64) {
        lock.withLock {
            if first == nil { first = start }
            if case let .snapshot(bytes) = message, snapshotIn == nil {
                snapshotIn = start
                snapshotOut = end
                size = bytes.count
            }
        }
    }
}

/// A `TerminalStreamLink` over the package's `TerminalStreamConnection`, on a serial
/// queue of its own, with the protocol's `stop()` kept by a callback lock and a stopped
/// flag. Throwaway: the shape the plan may build, not the one it must.
private final class WebSocketLink: TerminalStreamLink, @unchecked Sendable {
    private nonisolated(unsafe) static let key = DispatchSpecificKey<UInt8>()
    let probe = LinkProbe()
    private let connection: TerminalStreamConnection
    private let lock = NSLock()
    private let callbackLock = NSLock()
    private var isStopped = false
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?

    init(port: Int, token: String, session: String) {
        let queue = DispatchQueue(label: "step5.websocket-link")
        queue.setSpecific(key: Self.key, value: 1)
        connection = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "step5", host: "127.0.0.1", port: port, token: token),
            sessionId: session, resize: .reflow, callbackQueue: queue)
        connection.onMessage = { [weak self] message in self?.deliver(message) }
        connection.onEnded = { [weak self] reason in self?.end(reason) }
    }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }

    func start() {
        probe.markStarted()
        connection.start()
    }

    func stop() {
        lock.withLock { isStopped = true }
        connection.stop()
        if DispatchQueue.getSpecific(key: Self.key) == nil {
            callbackLock.lock()
            callbackLock.unlock()
        }
    }

    func send(_ bytes: [UInt8]) { connection.send(bytes) }
    func claim(cols: Int, rows: Int) { connection.claim(cols: cols, rows: rows) }

    private func deliver(_ message: StreamMessage) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard let handler = lock.withLock({ isStopped ? nil : messageHandler }) else { return }
        let start = now()
        handler(message)
        probe.handled(message, from: start, to: now())
    }

    private func end(_ reason: TerminalEndReason) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard let handler = lock.withLock({ isStopped ? nil : endHandler }) else { return }
        handler(reason)
    }
}

// MARK: - The serving side

/// A hub over libghostty-vt models this rig owns, wired as `GhosttyStack` wires one
/// without a pty (as `Step4bMeasurementTests` does), counting snapshots per session.
private final class StreamRig: @unchecked Sendable {
    let hub = PaneStreamHub(startTimer: true)
    private let lock = NSLock()
    private var models: [String: GhosttyVtScreenModel] = [:]
    private var snapshotCounts: [String: Int] = [:]

    init() {
        hub.onIngest = { [weak self] session, bytes in self?.model(session)?.write(bytes) }
        hub.onSnapshot = { [weak self] session in
            guard let self, let model = self.model(session) else { return nil }
            let frame = model.snapshotFrame()
            self.lock.withLock { self.snapshotCounts[session, default: 0] += 1 }
            return frame.bytes.isEmpty ? nil : frame
        }
        hub.onRepaint = { [weak self] session in self?.model(session)?.repaintFrame() }
        hub.onAlternateScreen = { [weak self] session in self?.model(session)?.isAlternateScreen ?? false }
        hub.onClaim = { [weak self] session, size in self?.model(session)?.resize(to: size) }
        hub.onSessionCensus = { [weak self] in
            guard let self else { return .unknown }
            return .sessions(self.lock.withLock { Set(self.models.keys) })
        }
    }

    func model(_ session: String) -> GhosttyVtScreenModel? { lock.withLock { models[session] } }
    func snapshots(of session: String) -> Int { lock.withLock { snapshotCounts[session, default: 0] } }

    func add(_ session: String, cols: Int, rows: Int, scrollback: Int) throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: cols, rows: rows),
                                             scrollbackLines: scrollback, graphemeClustering: true)
        lock.withLock { models[session] = model }
    }

    /// Lines straight into the model, before any viewer: coloured log lines, or with
    /// `dense` a 256 colour change every eight cells across 119 cells.
    func fill(_ session: String, lines: Int, dense: Bool = false) {
        guard let model = model(session) else { return }
        var from = 0
        while from < lines {
            let count = min(2_000, lines - from)
            model.write(dense ? Self.denseLines(from: from, count: count) : Self.logLines(from: from, count: count))
            from += count
        }
    }

    /// Through the hub, as the pty's reader would.
    func write(_ session: String, _ bytes: [UInt8]) { hub.write(session: session, bytes: bytes) }

    /// The session ends: its viewers are sent `ended`, and it leaves the census.
    func end(_ session: String) {
        hub.endViewers(ofSession: session)
        lock.withLock { models[session] = nil }
    }

    static func logLines(from: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 120)
        for n in from..<(from + count) {
            let line = "\u{1B}[2m2026-11-26 12:00:\(n % 60 + 10)\u{1B}[0m \u{1B}[32mINFO\u{1B}[0m "
                + "worker[\(n % 97)] processed item \(n) in \(n % 1000) ms, queue depth \(n % 31), status ok\r\n"
            out += Array(line.utf8)
        }
        return out
    }

    static func denseLines(from: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 300)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        for n in from..<(from + count) {
            var line: [UInt8] = []
            for cell in 0..<119 {
                if cell % 8 == 0 { line += Array("\u{1B}[38;5;\((n + cell) % 256)m".utf8) }
                line.append(alphabet[(n + cell) % alphabet.count])
            }
            line += Array("\u{1B}[0m\r\n".utf8)
            out += line
        }
        return out
    }
}

/// A `RemoteServer` on 127.0.0.1 with a throwaway token, over a `StreamRig`.
@MainActor
private final class ServerRig {
    let rig: StreamRig
    let server: RemoteServer
    let port: Int
    let token: String
    private let suite: String
    private let store: ProjectStore

    private init(server: RemoteServer, store: ProjectStore, port: Int, token: String, suite: String, rig: StreamRig) {
        self.server = server
        self.store = store
        self.port = port
        self.token = token
        self.suite = suite
        self.rig = rig
    }

    static func start() async throws -> ServerRig {
        let suite = "test.step5.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let token = RemoteAccessToken(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let rig = StreamRig()
        let server = RemoteServer(store: store, streamer: rig.hub, token: token, host: "127.0.0.1", port: 0)
        await server.start()
        let deadline = Date().addingTimeInterval(10)
        while server.boundPort == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let port = try #require(server.boundPort)
        return ServerRig(server: server, store: store, port: port, token: token.value, suite: suite, rig: rig)
    }

    func stop() {
        server.stop()
        rig.hub.stop()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

/// Feeds a session through the hub at a set rate, 4 KiB at a time, from a thread of
/// its own, until stopped.
private final class PacedFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var total = 0
    private let done = DispatchSemaphore(value: 0)

    var fed: Int { lock.withLock { total } }

    init(rig: StreamRig, session: String, bytesPerSecond: Int) {
        let source = StreamRig.logLines(from: 0, count: 12_000)
        let thread = Thread { [self] in
            let chunk = 4096
            let start = now()
            var offset = 0
            var sent = 0
            while lock.withLock({ running }) {
                let due = start + UInt64(Double(sent) / Double(bytesPerSecond) * 1e9)
                let current = now()
                if current < due { usleep(useconds_t(min(10_000, (due - current) / 1000))); continue }
                if offset + chunk > source.count { offset = 0 }
                rig.write(session, Array(source[offset..<(offset + chunk)]))
                offset += chunk
                sent += chunk
                lock.withLock { total = sent }
            }
            done.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        let wasRunning = lock.withLock {
            let was = running
            running = false
            return was
        }
        if wasRunning { done.wait() }
    }
}

private final class ClientCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var messageCount = 0
    private var data = 0
    private var snapshotCount = 0
    private var sawData = false
    private var reason: TerminalEndReason?

    var messages: Int { lock.withLock { messageCount } }
    var dataBytes: Int { lock.withLock { data } }
    var snapshots: Int { lock.withLock { snapshotCount } }
    var endText: String { lock.withLock { reason.map { "\($0)" } ?? "none" } }

    func received(_ message: StreamMessage) {
        lock.withLock {
            messageCount += 1
            switch message {
            case let .data(bytes): data += bytes.count
            case .snapshot: snapshotCount += 1
            default: break
            }
        }
    }

    /// True the first time only.
    func firstData() -> Bool {
        lock.withLock {
            defer { sawData = true }
            return !sawData
        }
    }

    func ended(_ value: TerminalEndReason) { lock.withLock { reason = value } }
}

private final class EndBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TerminalEndReason?
    var reason: TerminalEndReason? { lock.withLock { stored } }
    var text: String { reason.map { "\($0)" } ?? "none" }
    func set(_ value: TerminalEndReason) { lock.withLock { stored = value } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

// MARK: - The main queue's heartbeat

/// A 1 ms timer on the main queue, recording each gap between two fires.
@MainActor
private final class Heartbeat {
    private var timer: DispatchSourceTimer?
    private var last: UInt64 = 0
    private var samples: [(at: UInt64, gap: UInt64)] = []

    func start() {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.beat() } }
        source.resume()
        timer = source
    }

    private func beat() {
        let current = now()
        if last != 0 { samples.append((current, current - last)) }
        last = current
    }

    /// The longest gap that overlapped `[from, to]`.
    func maxGap(from: UInt64, to: UInt64) -> UInt64 {
        samples.filter { $0.at >= from && $0.at &- $0.gap <= to }.map(\.gap).max() ?? 0
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - What a process holds

/// The test host's descendants by name, its descriptors, threads and memory, and the
/// bridge socket files of this process.
private struct Census {
    let login: Int, bash: Int, helper: Int, other: Int, zombies: Int
    let descriptors: Int
    let threads: Int
    let sockets: Int
    let resident: UInt64
    let footprint: UInt64

    static func take() -> Census {
        let rows = processRows()
        var children: [Int32: [ProcessRow]] = [:]
        for row in rows { children[row.ppid, default: []].append(row) }
        var stack = [getpid()]
        var found: [ProcessRow] = []
        while let pid = stack.popLast() {
            for child in children[pid] ?? [] where child.command != "ps" {
                found.append(child)
                stack.append(child.pid)
            }
        }
        let names = found.map { ($0.command as NSString).lastPathComponent }
        let memory = processMemory()
        let directory = NSTemporaryDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let sockets = files.filter { $0.hasPrefix("wty-\(getpid())-") || $0.hasPrefix(".wty-") }.count
        return Census(login: names.filter { $0 == "login" }.count,
                      bash: names.filter { $0 == "bash" }.count,
                      helper: names.filter { $0 == "wietty-pty" }.count,
                      other: names.filter { !["login", "bash", "wietty-pty"].contains($0) }.count,
                      zombies: found.filter { $0.state.hasPrefix("Z") }.count,
                      descriptors: descriptorCount(), threads: threadCount(), sockets: sockets,
                      resident: memory.resident, footprint: memory.footprint)
    }

    func describe(against before: Census) -> String {
        """
        login=\(login) bash=\(bash) wietty-pty=\(helper) otherChildren=\(other) zombies=\(zombies) \
        fds=\(descriptors)(\(signed(descriptors - before.descriptors))) \
        threads=\(threads)(\(signed(threads - before.threads))) bridgeSockets=\(sockets) \
        residentMiB=\(mib(resident))(\(signedMiB(resident, before.resident))) \
        footprintMiB=\(mib(footprint))(\(signedMiB(footprint, before.footprint)))
        """
    }

    private func signed(_ value: Int) -> String { value >= 0 ? "+\(value)" : "\(value)" }
}

private struct ProcessRow {
    let pid: Int32
    let ppid: Int32
    let state: String
    let command: String
}

private func processRows() -> [ProcessRow] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-A", "-o", "pid=,ppid=,stat=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
        return ProcessRow(pid: pid, ppid: ppid, state: String(parts[2]),
                          command: String(parts[3]).trimmingCharacters(in: .whitespaces))
    }
}

private func descriptorCount() -> Int {
    let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return -1 }
    let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride + 64
    var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let used = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &buffer, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
    return Int(used) / MemoryLayout<proc_fdinfo>.stride
}

private func threadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                  vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return Int(count)
}

private func processMemory() -> (resident: UInt64, footprint: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (info.resident_size, info.phys_footprint)
}

/// The receive queue of the client's socket to `port` and the send queue of the
/// server's socket for it, from `netstat`; 0 when not found.
private func tcpQueues(port: Int) -> (clientRecvQ: Int, serverSendQ: Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-an", "-p", "tcp"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (0, 0) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var recv = 0, send = 0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6, parts[5] == "ESTABLISHED", let recvQ = Int(parts[1]), let sendQ = Int(parts[2]) else { continue }
        if parts[4] == "127.0.0.1.\(port)" { recv = max(recv, recvQ) }
        if parts[3] == "127.0.0.1.\(port)" { send = max(send, sendQ) }
    }
    return (recv, send)
}

// MARK: - Helpers

private enum Step5Error: Error {
    case neverSettled
}

/// Prints a result line on a line of its own, flushed.
private func report(_ line: String) {
    print(line)
    fflush(stdout)
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func ms(_ nanoseconds: UInt64) -> String { String(format: "%.1f", Double(nanoseconds) / 1e6) }

private func mib(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
private func mib(_ bytes: Int) -> String { mib(UInt64(max(0, bytes))) }

private func signedMiB(_ value: UInt64, _ base: UInt64) -> String {
    String(format: "%+.1f", (Double(value) - Double(base)) / 1_048_576)
}

/// Nearest rank median, p95 and max, in milliseconds.
private func summary(_ samples: [UInt64]) -> String {
    guard !samples.isEmpty else { return "n=0" }
    let sorted = samples.sorted()
    func quantile(_ q: Double) -> UInt64 {
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
    return "median=\(ms(quantile(0.5)))ms p95=\(ms(quantile(0.95)))ms max=\(ms(sorted[sorted.count - 1]))ms n=\(sorted.count)"
}

/// Control bytes made visible: ESC as `\e`, others as `\xNN`.
private func escaped(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x1B: out += "\\e"
        case 0x00..<0x20, 0x7F: out += String(format: "\\x%02x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out.isEmpty ? "(none)" : out
}

/// Trailing spaces and trailing blank rows are not content.
private func normalised(_ rows: [String]) -> [String] {
    var rows = rows.map { row -> String in
        var row = row
        while row.hasSuffix(" ") { row.removeLast() }
        return row
    }
    while rows.last?.isEmpty == true { rows.removeLast() }
    return rows
}

private func lastLines(_ rows: [String], _ count: Int) -> String {
    normalised(rows).filter { !$0.isEmpty }.suffix(count).map { $0.debugDescription }.joined(separator: " | ")
}

private func firstDifference(_ surface: [String], _ model: [String]) -> String {
    let count = max(surface.count, model.count)
    let differing = (0..<count).filter { index in
        (index < surface.count ? surface[index] : nil) != (index < model.count ? model[index] : nil)
    }
    guard let first = differing.first else { return "none" }
    return """
        \(differing.count) of \(count) lines differ (surface \(surface.count), model \(model.count)); \
        first at \(first): surface \((first < surface.count ? surface[first] : "<none>").debugDescription) \
        model \((first < model.count ? model[first] : "<none>").debugDescription)
        """
}

/// Polls `condition` on the main actor until it holds or `seconds` pass.
@MainActor
private func waitUntil(_ seconds: Double, poll: Duration = .milliseconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = now() + UInt64(seconds * 1e9)
    while now() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return condition()
}

/// Runs a blocking body on a thread of its own.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}
