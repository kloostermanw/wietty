import Darwin
import Foundation
import Testing
import WiettyCore
@testable import WiettyShared
@testable import Wietty

/// Measurements of four suspected weaknesses of the terminal stream, for the design of
/// phase 3 step 4b of issue #84: the hub's one delivery queue under a claim flood (A),
/// the session and model locks under an output flood with claims and resyncs (B), a
/// local attach whose snapshot is written from the delivery queue (C), and a client of
/// the package that may lose `ended` or `error` to the close the route sends right after
/// it (D).
///
/// A measurement, not a test: it asserts only what it needs to stay meaningful, and
/// prints lines starting with `STEP4B`. Every measurement runs three times and prints
/// each run.
///
/// **Not part of the normal suite.** It takes minutes, saturates cores and its numbers
/// mean nothing beside a parallel run. It runs only with `WIETTY_STEP4B=1` in the test
/// host's environment:
///
/// ```sh
/// TEST_RUNNER_WIETTY_STEP4B=1 xcodebuild -scheme Wietty -destination 'platform=macOS' \
///   -only-testing:WiettyTests/Step4bMeasurementTests test
/// ```
///
/// Built the way the app builds a terminal's server side, without a pty: a real
/// `PaneStreamHub` with its flush timer, a real libghostty-vt model per session wired
/// to the same hooks `GhosttyStack` sets (`onClaim` resizes the model only, since there
/// is no pty to signal), and the bytes written into the hub from threads that stand
/// where the pty's read thread stands.
@Suite(.enabled(if: Step4b.isRequested), .serialized)
struct Step4bMeasurementTests {
    static let runs = 3

    // MARK: A. Claim flood

    /// One queued viewer of session X claims two grids in turn while session Y prints a
    /// 16 byte line every 2 ms to a queued viewer of its own. Y's delay is from just
    /// before `write` to its viewer's sink. Phases: no claims; one claim per 50 ms (the
    /// pane's own limit, a window drag); a closed loop that claims again from the sink
    /// the moment the last claim is answered (the most the hub accepts without a
    /// backlog); a burst of 20 claims sent at once (an open loop client).
    @Test func aClaimFlood() throws {
        let cases: [(label: String, history: Int, scrollback: Int)] = [
            ("small300", 300, TerminalScrollback.defaultLines),
            ("full10k", TerminalScrollback.defaultLines + 200, TerminalScrollback.defaultLines),
            ("full100k", 100_200, 100_000),
        ]
        for run in 1...Self.runs {
            for item in cases {
                try Self.claimFlood(run: run, label: item.label, history: item.history,
                                    scrollback: item.scrollback)
            }
        }
    }

    private static func claimFlood(run: Int, label: String, history: Int, scrollback: Int) throws {
        let rig = Rig()
        defer { rig.close() }
        try rig.addSession("x", scrollback: scrollback)
        rig.fill("x", lines: history)
        try rig.addSession("y", scrollback: 1_000)
        let probe = SteadyProbe(hub: rig.hub, session: "y")
        defer { probe.stop() }
        let driver = ClaimDriver(hub: rig.hub, session: "x", local: false)
        defer { driver.detach() }
        Thread.sleep(forTimeInterval: 0.5)
        let prefix = "STEP4B A run=\(run) hist=\(label)"

        probe.mark()
        Thread.sleep(forTimeInterval: 2)
        report("\(prefix) phase=none ydelay \(summary(probe.collect()))")

        // Paced, one claim per 50 ms.
        rig.resetStats(); driver.resetStats(); probe.mark()
        let pacedEnd = now() + 3_000_000_000
        while now() < pacedEnd {
            driver.claimNext()
            usleep(50_000)
        }
        #expect(driver.waitForAnswers(within: 60))
        let paced = probe.collect()
        let pacedStats = rig.stats()
        report("""
            \(prefix) phase=paced50ms ydelay \(summary(paced)) \
            | claimLatency \(summary(driver.latencies())) \
            | reflow \(summary(pacedStats.claims.map { $0.end - $0.start })) \
            | repaint \(summary(pacedStats.repaints.map { $0.end - $0.start }))
            """)

        // Closed loop: the sink claims again as soon as a claim is answered.
        rig.resetStats(); driver.resetStats(); probe.mark()
        let floodStart = now()
        driver.startLoop()
        Thread.sleep(forTimeInterval: 3)
        driver.stopLoop()
        #expect(driver.waitForAnswers(within: 60))
        let floodNs = now() - floodStart
        let flood = probe.collect()
        let floodStats = rig.stats()
        let rate = Double(driver.answered()) / (Double(floodNs) / 1e9)
        report("""
            \(prefix) phase=flood ydelay \(summary(flood)) \
            | claimsPerSecond=\(String(format: "%.1f", rate)) \
            | reflow \(summary(floodStats.claims.map { $0.end - $0.start })) \
            | repaint \(summary(floodStats.repaints.map { $0.end - $0.start }))
            """)

        // A burst of 20 claims sent at once.
        Thread.sleep(forTimeInterval: 0.3)
        rig.resetStats(); driver.resetStats(); probe.mark()
        let burstStart = now()
        for _ in 0..<20 { driver.claimNext() }
        #expect(driver.waitForAnswers(within: 120))
        let drain = now() - burstStart
        Thread.sleep(forTimeInterval: 0.1)
        report("\(prefix) phase=burst20 ydelay \(summary(probe.collect())) | drainMs=\(ms(drain))")
    }

    // MARK: B. Output flood with claims and resyncs

    /// Session X is fed 4 KiB chunks flat out by a thread standing where the pty's read
    /// thread stands, its scrollback full (10,000 lines). Its viewer is either a queued
    /// one (repaint mode, as a browser or an iPad) or a local one (reflow, as the pane,
    /// whose write returns at once). After two seconds of flood alone, three seconds of
    /// flood with a claim every 50 ms from X's viewer and, for the queued viewer, a
    /// resync of it every 250 ms (`ResyncThrottle`'s most).
    @Test func bOutputFloodWithClaims() throws {
        for run in 1...Self.runs {
            for local in [false, true] {
                try Self.outputFlood(run: run, local: local)
            }
        }
    }

    private static func outputFlood(run: Int, local: Bool) throws {
        let rig = Rig()
        defer { rig.close() }
        try rig.addSession("x", scrollback: TerminalScrollback.defaultLines)
        rig.fill("x", lines: TerminalScrollback.defaultLines + 200)
        try rig.addSession("y", scrollback: 1_000)
        let probe = SteadyProbe(hub: rig.hub, session: "y")
        defer { probe.stop() }
        let driver = ClaimDriver(hub: rig.hub, session: "x", local: local)
        defer { driver.detach() }
        Thread.sleep(forTimeInterval: 0.3)
        let feeder = Feeder(hub: rig.hub, session: "x")
        defer { feeder.stop() }
        let prefix = "STEP4B B run=\(run) viewer=\(local ? "local" : "queued")"

        Thread.sleep(forTimeInterval: 0.5)
        probe.mark()
        let floodFrom = feeder.mark()
        Thread.sleep(forTimeInterval: 2)
        let floodTo = feeder.mark()
        let floodOnly = probe.collect()
        let floodWrites = feeder.spans(floodFrom..<floodTo)
        report("""
            \(prefix) phase=flood ydelay \(summary(floodOnly)) \
            | xMiBps=\(feeder.rate(floodFrom..<floodTo)) \
            | xWrite \(summary(floodWrites.map { $0.end - $0.start }))
            """)

        rig.resetStats(); driver.resetStats(); probe.mark()
        let claimsFrom = feeder.mark()
        let end = now() + 3_000_000_000
        var nextResync = now()
        while now() < end {
            driver.claimNext()
            if !local, now() >= nextResync {
                driver.resync()
                nextResync = now() + 250_000_000
            }
            usleep(50_000)
        }
        #expect(driver.waitForAnswers(within: 60))
        let claimsTo = feeder.mark()
        let withClaims = probe.collect()
        let writes = feeder.spans(claimsFrom..<claimsTo)
        let stats = rig.stats()
        let calls = driver.callTimes()
        let answers = driver.answerTimes()
        // Per claim: from the call to the start of `onClaim` (waiting on the delivery
        // queue), `onClaim` itself (the model's lock and the reflow), and the longest
        // write of the feeder that overlapped the claim from `onClaim` to its answer.
        var waits: [UInt64] = []
        var held: [UInt64] = []
        for (index, span) in stats.claims.enumerated() where index < calls.count && index < answers.count {
            waits.append(span.start &- calls[index])
            held.append(Self.longestWrite(writes, overlapping: span.start, answers[index]))
        }
        // From the end of the reflow to the start of the repaint, which `resizeNow` takes
        // under the session's lock: mostly the wait for that lock.
        var lockWaits: [UInt64] = []
        for (index, span) in stats.claims.enumerated() where index < stats.repaints.count {
            lockWaits.append(stats.repaints[index].start &- span.end)
        }
        // From a resync's call to the start of its snapshot, taken under the same lock.
        let resyncCalls = driver.resyncTimes()
        var resyncWaits: [UInt64] = []
        for (index, snapshot) in stats.snapshots.enumerated() where index < resyncCalls.count {
            resyncWaits.append(snapshot.start &- resyncCalls[index])
        }
        let snapshotHeld = stats.snapshots.map { Self.longestWrite(writes, overlapping: $0.start, $0.end) }
        report("""
            \(prefix) phase=flood+claims ydelay \(summary(withClaims)) \
            | xMiBps=\(feeder.rate(claimsFrom..<claimsTo)) \
            | xWrite \(summary(writes.map { $0.end - $0.start })) \
            | claimQueueWait \(summary(waits)) \
            | onClaim \(summary(stats.claims.map { $0.end - $0.start })) \
            | claimToAnswer \(summary(driver.latencies())) \
            | writerHeldPerClaim \(summary(held)) \
            | reflowToRepaint \(summary(lockWaits)) \
            | repaint \(summary(stats.repaints.map { $0.end - $0.start })) \
            | resyncCallToSnapshot \(summary(resyncWaits)) \
            | resyncSnapshot \(summary(stats.snapshots.map { $0.end - $0.start })) \
            | writerHeldPerResync \(summary(snapshotHeld)) \
            | snapshotBytes=\(stats.snapshots.last?.bytes ?? 0)
            """)
    }

    /// The longest write that overlapped `[from, to]`.
    private static func longestWrite(_ writes: [Span], overlapping from: UInt64, _ to: UInt64) -> UInt64 {
        var longest: UInt64 = 0
        for write in writes where write.end >= from && write.start <= to {
            longest = max(longest, write.end - write.start)
        }
        return longest
    }

    // MARK: C. A local attach

    /// A client of `LocalStreamServer` attaches to session X, whose history is small
    /// (300 lines) or full (10,000 or 100,000 lines). The hub formats the snapshot on its
    /// delivery queue (`attachLocal` runs `attachLocalNow` with `delivery.sync`), and,
    /// since step 4b (Q2), the connection's own thread writes it, whole, once the queue
    /// has let go; before that the batch was `run` on the queue. Readers: at once; slowly, 32 KiB
    /// every 100 ms; stalled 4.5 s then at once; stopped (never reads, so the 5 second
    /// progress deadline ends it). Measured: Y's delay as in A, how long a probe that
    /// waits for the delivery queue (`waitForPendingDeliveries`) was held at most, and
    /// from the hello written to the snapshot read whole.
    @Test func cLocalAttach() throws {
        let cases: [(label: String, history: Int, scrollback: Int, readers: [Reader])] = [
            ("small300", 300, TerminalScrollback.defaultLines, [.fast, .slow, .stalled]),
            ("full10k", TerminalScrollback.defaultLines + 200, TerminalScrollback.defaultLines,
             [.fast, .slow, .stalled, .stopped]),
            ("full100k", 100_200, 100_000, [.fast]),
        ]
        for run in 1...Self.runs {
            for item in cases {
                for reader in item.readers {
                    try Self.localAttach(run: run, label: item.label, history: item.history,
                                         scrollback: item.scrollback, reader: reader)
                }
            }
        }
    }

    enum Reader: String {
        case fast, slow, stalled, stopped
    }

    private static func localAttach(run: Int, label: String, history: Int, scrollback: Int,
                                    reader: Reader) throws {
        let rig = Rig()
        defer { rig.close() }
        try rig.addSession("x", scrollback: scrollback)
        rig.fill("x", lines: history)
        try rig.addSession("y", scrollback: 1_000)
        let probe = SteadyProbe(hub: rig.hub, session: "y")
        defer { probe.stop() }
        let server = try LocalStreamServer(path: shortSocketPath("s4b"), streamer: rig.hub)
        server.start()
        defer { server.stop() }
        let occupancy = QueueProbe(hub: rig.hub)
        defer { occupancy.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        let prefix = "STEP4B C run=\(run) hist=\(label) reader=\(reader.rawValue)"

        probe.mark(); occupancy.mark()
        let client = try Socket(connectingTo: server.path)
        defer { client.close() }
        let hello = try StreamCodec.checkedSocketFrame(
            for: .hello(protocolVersion: StreamProtocol.version, session: "x", resize: .reflow))
        let start = now()
        try client.writeAll(hello)
        var frames = StreamFrameReader(maxPayload: StreamProtocol.maxMessageSize)
        var snapshotBytes = 0
        var outcome = "snapshot"
        switch reader {
        case .fast, .slow, .stalled:
            if reader == .stalled { Thread.sleep(forTimeInterval: 4.5) }
            let chunk = reader == .slow ? 32 << 10 : 1 << 20
            readLoop: while true {
                guard let bytes = client.read(max: chunk, timeout: 30) else { outcome = "closed"; break }
                for message in try frames.append(bytes) {
                    if case let .snapshot(payload) = message {
                        snapshotBytes = payload.count
                        break readLoop
                    }
                }
                if reader == .slow { usleep(100_000) }
            }
        case .stopped:
            // Never reads. The server's deadline ends the connection; wait past it.
            Thread.sleep(forTimeInterval: 6.5)
            outcome = client.isHungUp() ? "droppedByServer" : "stillOpen"
        }
        let attach = now() - start
        Thread.sleep(forTimeInterval: 0.3)
        report("""
            \(prefix) outcome=\(outcome) snapshotBytes=\(snapshotBytes) \
            | helloToSnapshotMs=\(ms(attach)) \
            | queueBusyMax=\(ms(occupancy.collectMax())) \
            | ydelay \(summary(probe.collect()))
            """)
    }

    // MARK: D. The close after the last frame

    /// The package's own client, `TerminalStreamConnection` (what
    /// `RemoteTerminalConnection` wraps), against a real `RemoteServer` on 127.0.0.1
    /// with a real hub behind it, a throwaway token, 200 attaches per case:
    ///
    /// - `ended-*`: attached, the snapshot received, then the client sends input (or a
    ///   claim, or nothing) every millisecond, and after 2 to 20 ms the session ends
    ///   (`endViewers`). The route writes `ended` and returns, which closes.
    /// - `refused-protocol`, `refused-session`: the attach URL is rewritten to name
    ///   protocol 3, or no session; the client sends input from the moment it starts
    ///   (the client holds it until a hello, which never comes).
    /// - `notlive-*`: a session the census does not know: `hello`, `ended` and the close
    ///   at once, while the client sends nothing, sends input every millisecond from its
    ///   start, or makes one claim at its start; what it held is written the moment the
    ///   hello is read.
    /// - `raw-refused-protocol`: a bare `URLSessionWebSocketTask` that sends a data frame
    ///   every millisecond from the start, to see what the transport does when bytes do
    ///   go out against the refusal; the package's client never sends before the hello.
    ///
    /// Counted: how often the end reason is the right one.
    @Test @MainActor func dCloseAfterTheLastFrame() async throws {
        let suite = "test.step4b.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let token = RemoteAccessToken(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let rig = Rig(census: true)
        defer { rig.close() }
        let server = RemoteServer(store: store, streamer: rig.hub, token: token,
                                  host: "127.0.0.1", port: 0)
        await server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(10)
        while server.boundPort == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let port = try #require(server.boundPort)
        let secret = token.value
        let attaches = 200

        try await offMain {
            for run in 1...Self.runs {
                for kind in CloseCase.allCases {
                    var counts: [String: Int] = [:]
                    for index in 0..<attaches {
                        let result = try Self.closeAttempt(kind, rig: rig, port: port, token: secret,
                                                           index: index, run: run)
                        counts[result, default: 0] += 1
                    }
                    let tally = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                    let right = counts[kind.expected, default: 0]
                    report("STEP4B D run=\(run) case=\(kind.rawValue) right=\(right)/\(attaches) \(tally)")
                }
            }
        }
    }

    enum CloseCase: String, CaseIterable {
        case endedQuiet = "ended-nosend"
        case endedInput = "ended-input"
        case endedClaim = "ended-claim"
        case refusedProtocol = "refused-protocol"
        case refusedSession = "refused-session"
        case notLiveQuiet = "notlive-nosend"
        case notLive = "notlive-input"
        case notLiveOneClaim = "notlive-oneclaim"
        case rawRefusedProtocol = "raw-refused-protocol"

        var expected: String {
            switch self {
            case .endedQuiet, .endedInput, .endedClaim, .notLive, .notLiveQuiet, .notLiveOneClaim:
                "sessionEnded"
            case .refusedProtocol, .rawRefusedProtocol: "refused(protocol)"
            case .refusedSession: "refused(session)"
            }
        }
    }

    private static func describe(_ reason: TerminalEndReason?) -> String {
        switch reason {
        case nil: "noEnd"
        case .sessionEnded: "sessionEnded"
        case .connectionLost: "connectionLost"
        case .serverTooOld: "serverTooOld"
        case let .refused(code, _): "refused(\(code))"
        }
    }

    private static func closeAttempt(_ kind: CloseCase, rig: Rig, port: Int, token: String,
                                     index: Int, run: Int) throws -> String {
        let session = "d\(run)-\(kind.rawValue)-\(index)"
        if kind == .rawRefusedProtocol {
            return rawRefusal(port: port, token: token, session: session)
        }
        let live = kind == .endedQuiet || kind == .endedInput || kind == .endedClaim
        if live {
            try rig.addSession(session, cols: 80, rows: 24, scrollback: 1_000)
            rig.fill(session, lines: 5)
        }
        let rewrite: @Sendable (URL) -> URL = { url in
            var text = url.absoluteString
            switch kind {
            case .refusedProtocol:
                text = text.replacingOccurrences(of: "protocol=\(StreamProtocol.version)", with: "protocol=3")
            case .refusedSession:
                if let range = text.range(of: #"session=[^&]*&"#, options: .regularExpression) {
                    text.removeSubrange(range)
                }
            default: break
            }
            return URL(string: text)!
        }
        let trace = Trace()
        let connection = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "step4b", host: "127.0.0.1", port: port, token: token),
            sessionId: session, resize: .repaint,
            callbackQueue: DispatchQueue(label: "step4b.client"),
            transport: { url in
                TracingTransport(task: URLSession.shared.webSocketTask(with: rewrite(url)), trace: trace)
            })
        let recorder = EndRecorder()
        connection.onMessage = { message in
            if case .snapshot = message { recorder.first.signal() }
        }
        connection.onEnded = { reason in recorder.end(reason) }
        connection.start()
        defer { connection.stop() }

        let sender = Sender()
        defer { sender.stop() }
        switch kind {
        case .endedQuiet, .endedInput, .endedClaim:
            guard recorder.first.wait(timeout: .now() + 5) == .success else {
                rig.hub.endViewers(ofSession: session)
                rig.removeSession(session)
                return "noSnapshot(" + describe(recorder.reason) + ")"
            }
            if kind == .endedInput {
                sender.start { _ in connection.send([0x61]) }
            } else if kind == .endedClaim {
                sender.start { tick in tick % 2 == 0 ? connection.claim(cols: 80, rows: 24)
                                                     : connection.claim(cols: 100, rows: 30) }
            }
            usleep(useconds_t.random(in: 2_000...20_000))
            rig.hub.endViewers(ofSession: session)
            rig.removeSession(session)
        case .notLiveQuiet:
            break
        case .notLiveOneClaim:
            // One claim, held until the hello and written the moment it is read.
            connection.claim(cols: 80, rows: 24)
        default:
            sender.start { _ in connection.send([0x61]) }
        }
        _ = recorder.ended.wait(timeout: .now() + 5)
        let reason = recorder.reason
        guard reason == .connectionLost else { return describe(reason) }
        // Which call of the socket failed first, and whether the transport had already
        // handed over the `ended` or `error` frame by then.
        return "connectionLost[first=\(trace.firstFailure),endFrameRead=\(trace.sawEndFrame)]"
    }

    /// A bare `URLSessionWebSocketTask` refused for its protocol, sending a data frame
    /// every millisecond from the moment it starts. Whether its first receive is the
    /// `error` frame, or fails.
    private static func rawRefusal(port: Int, token: String, session: String) -> String {
        let url = URL(string: "ws://127.0.0.1:\(port)/attach?session=\(session)&token=\(token)&protocol=3&resize=repaint")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = StreamProtocol.maxMessageSize
        task.resume()
        let sender = Sender()
        var text: String?
        var data: Data?
        switch StreamCodec.webSocketFrame(for: .data([0x61])) {
        case let .text(value): text = value
        case let .binary(bytes): data = Data(bytes)
        }
        let frameText = text
        let frameData = data
        sender.start { _ in
            if let frameText { task.send(.string(frameText)) { _ in } }
            if let frameData { task.send(.data(frameData)) { _ in } }
        }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        task.receive { result in
            switch result {
            case let .success(message):
                let decoded: StreamMessage? = switch message {
                case let .string(text): StreamCodec.message(from: .text(text))
                case let .data(data): StreamCodec.message(from: .binary(Array(data)))
                @unknown default: nil
                }
                if case let .error(code, _) = decoded { box.set("refused(\(code))") } else { box.set("other") }
            case .failure:
                box.set("connectionLost")
            }
            done.signal()
        }
        let outcome = done.wait(timeout: .now() + 5) == .success ? box.value : "noEnd"
        sender.stop()
        task.cancel(with: .goingAway, reason: nil)
        return outcome
    }
}

/// Forwards to a `URLSessionWebSocketTask` and notes which call failed first.
private final class TracingTransport: WebSocketTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let trace: Trace

    init(task: URLSessionWebSocketTask, trace: Trace) {
        self.task = task
        self.trace = trace
    }

    var maximumMessageSize: Int {
        get { task.maximumMessageSize }
        set { task.maximumMessageSize = newValue }
    }

    func resume() { task.resume() }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {
        let trace = self.trace
        task.receive { result in
            switch result {
            case let .success(message):
                let decoded: StreamMessage? = switch message {
                case let .string(text): StreamCodec.message(from: .text(text))
                case let .data(data): StreamCodec.message(from: .binary(Array(data)))
                @unknown default: nil
                }
                switch decoded {
                case .ended, .error: trace.endFrameRead()
                default: break
                }
            case .failure:
                trace.failed("receive")
            }
            completionHandler(result)
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let trace = self.trace
        task.send(message) { error in
            if error != nil { trace.failed("send") }
            completionHandler(error)
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        trace.failed("cancelled")
        task.cancel(with: closeCode, reason: reason)
    }
}

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    private var endRead = false

    var firstFailure: String { lock.withLock { first ?? "none" } }
    var sawEndFrame: Bool { lock.withLock { endRead } }

    func failed(_ call: String) { lock.withLock { if first == nil { first = call } } }
    func endFrameRead() { lock.withLock { endRead = true } }
}

enum Step4b {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_STEP4B"] == "1"
    }
}

// MARK: - The rig

/// Prints a result line on a line of its own, flushed, so the system's log lines do
/// not land in the middle of it.
private func report(_ line: String) {
    print(line)
    fflush(stdout)
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func ms(_ nanoseconds: UInt64) -> String {
    String(format: "%.3f", Double(nanoseconds) / 1e6)
}

/// Nearest rank median, p95 and max, in milliseconds.
private func summary(_ samples: [UInt64]) -> String {
    guard !samples.isEmpty else { return "n=0" }
    let sorted = samples.sorted()
    func quantile(_ q: Double) -> UInt64 {
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
    return "median=\(ms(quantile(0.5))) p95=\(ms(quantile(0.95))) max=\(ms(sorted[sorted.count - 1])) n=\(sorted.count)"
}

private struct Span: Sendable {
    let start: UInt64
    let end: UInt64
}

/// Runs a blocking body on a thread of its own.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// A hub with the hooks `GhosttyStack` sets, over libghostty-vt models this rig owns,
/// timing the calls that run under a session's lock or on the delivery queue.
private final class Rig: @unchecked Sendable {
    let hub = PaneStreamHub(startTimer: true)
    private let lock = NSLock()
    private var models: [String: GhosttyVtScreenModel] = [:]
    private var claimSpans: [Span] = []
    private var repaintSpans: [Span] = []
    private var snapshotSpans: [(start: UInt64, end: UInt64, bytes: Int)] = []

    init(census: Bool = false) {
        hub.onIngest = { [weak self] session, bytes in self?.model(session)?.write(bytes) }
        hub.onSnapshot = { [weak self] session in
            guard let self, let model = self.model(session) else { return nil }
            let start = now()
            let frame = model.snapshotFrame()
            let end = now()
            self.lock.withLock { self.snapshotSpans.append((start, end, frame.bytes.count)) }
            return frame.bytes.isEmpty ? nil : frame
        }
        hub.onRepaint = { [weak self] session in
            guard let self, let model = self.model(session) else { return nil }
            let start = now()
            let frame = model.repaintFrame()
            let end = now()
            self.lock.withLock { self.repaintSpans.append(Span(start: start, end: end)) }
            return frame
        }
        hub.onAlternateScreen = { [weak self] session in self?.model(session)?.isAlternateScreen ?? false }
        hub.onClaim = { [weak self] session, size in
            guard let self, let model = self.model(session) else { return }
            let start = now()
            model.resize(to: size)
            let end = now()
            self.lock.withLock { self.claimSpans.append(Span(start: start, end: end)) }
        }
        if census {
            hub.onSessionCensus = { [weak self] in
                guard let self else { return .unknown }
                return .sessions(self.lock.withLock { Set(self.models.keys) })
            }
        }
    }

    func model(_ session: String) -> GhosttyVtScreenModel? {
        lock.withLock { models[session] }
    }

    func addSession(_ session: String, cols: Int = 120, rows: Int = 34, scrollback: Int) throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: cols, rows: rows),
                                             scrollbackLines: scrollback, graphemeClustering: true)
        lock.withLock { models[session] = model }
    }

    func removeSession(_ session: String) {
        lock.withLock { models[session] = nil }
    }

    /// Writes `lines` coloured log lines straight into the model, before any viewer.
    func fill(_ session: String, lines: Int) {
        guard let model = model(session) else { return }
        var from = 0
        while from < lines {
            let count = min(2_000, lines - from)
            model.write(Self.logLines(from: from, count: count))
            from += count
        }
    }

    static func logLines(from: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 120)
        for n in from..<(from + count) {
            let line = "\u{1B}[2m2026-11-25 12:00:\(n % 60 + 10)\u{1B}[0m \u{1B}[32mINFO\u{1B}[0m "
                + "worker[\(n % 97)] processed item \(n) in \(n % 1000) ms, queue depth \(n % 31), status ok\r\n"
            out += Array(line.utf8)
        }
        return out
    }

    func resetStats() {
        lock.withLock {
            claimSpans = []
            repaintSpans = []
            snapshotSpans = []
        }
    }

    func stats() -> (claims: [Span], repaints: [Span], snapshots: [(start: UInt64, end: UInt64, bytes: Int)]) {
        lock.lock()
        defer { lock.unlock() }
        return (claims: claimSpans, repaints: repaintSpans, snapshots: snapshotSpans)
    }

    func close() {
        hub.stop()
    }
}

/// Session Y: a 16 byte line every 2 ms into the hub, from a thread of its own, and a
/// queued viewer whose sink records how long each line took from just before `write`
/// to the sink. Lines are fixed size and the viewer attached before the first, so the
/// byte offset says which line arrived.
private final class SteadyProbe: @unchecked Sendable {
    static let chunk = 16
    private let hub: PaneStreamHub
    private let session: String
    private let capacity = 1 << 20
    private let accepted: UnsafeMutablePointer<UInt64>
    private let lock = NSLock()
    private var received = 0
    private var delays: [UInt64] = []
    private var running = true
    private let done = DispatchSemaphore(value: 0)
    private var viewer: UUID?

    init(hub: PaneStreamHub, session: String) {
        self.hub = hub
        self.session = session
        accepted = .allocate(capacity: capacity)
        viewer = hub.attach(session: session, resize: .reflow) { [weak self] message in
            self?.receive(message)
        }
        let thread = Thread { [self] in produce() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { accepted.deallocate() }

    private var isRunning: Bool { lock.withLock { running } }

    private func produce() {
        var index = 0
        while isRunning, index < capacity {
            let bytes = Array(String(format: "Y%013d\r\n", index).utf8)
            accepted[index] = now()
            hub.write(session: session, bytes: bytes)
            index += 1
            usleep(2_000)
        }
        done.signal()
    }

    private func receive(_ message: StreamMessage) {
        guard case let .data(bytes) = message else { return }
        let time = now()
        lock.lock()
        let before = received / Self.chunk
        received += bytes.count
        let after = received / Self.chunk
        for line in before..<after { delays.append(time &- accepted[line]) }
        lock.unlock()
    }

    func mark() { lock.withLock { delays = [] } }

    func collect() -> [UInt64] { lock.withLock { delays } }

    func stop() {
        lock.withLock { running = false }
        done.wait()
        if let viewer { hub.detach(connectionId: viewer) }
    }
}

/// A viewer of session X that claims two grids in turn and records each claim's call
/// and answer.
private final class ClaimDriver: @unchecked Sendable {
    private let hub: PaneStreamHub
    private let grids = [TerminalSize(cols: 120, rows: 34), TerminalSize(cols: 100, rows: 30)]
    private let lock = NSLock()
    private var viewer: UUID?
    private var next = 0
    private var looping = false
    private var outstanding: [UInt64] = []
    private var calls: [UInt64] = []
    private var answers: [UInt64] = []
    private var latencyList: [UInt64] = []
    private var resyncs: [UInt64] = []

    init(hub: PaneStreamHub, session: String, local: Bool) {
        self.hub = hub
        let sink: @Sendable (StreamMessage) -> Void = { [weak self] message in self?.receive(message) }
        let id = local ? hub.attachLocal(session: session, resize: .reflow, write: sink)
                       : hub.attach(session: session, resize: .repaint, onMessage: sink)
        lock.withLock { viewer = id }
    }

    private func receive(_ message: StreamMessage) {
        guard case .resize(_, _, true) = message else { return }
        let time = now()
        lock.lock()
        answers.append(time)
        if !outstanding.isEmpty { latencyList.append(time - outstanding.removeFirst()) }
        let again = looping
        lock.unlock()
        if again { claimNext() }
    }

    func claimNext() {
        lock.lock()
        let grid = grids[next]
        next ^= 1
        let time = now()
        outstanding.append(time)
        calls.append(time)
        let id = viewer
        lock.unlock()
        guard let id else { return }
        hub.claim(connectionId: id, cols: grid.cols, rows: grid.rows)
    }

    func resync() {
        guard let id = lock.withLock({ viewer }) else { return }
        lock.withLock { resyncs.append(now()) }
        hub.resync(connectionId: id) {}
    }

    func startLoop() {
        lock.withLock { looping = true }
        claimNext()
    }

    func stopLoop() { lock.withLock { looping = false } }

    func waitForAnswers(within seconds: Double) -> Bool {
        waitUntil(within: seconds) { lock.withLock { outstanding.isEmpty } }
    }

    func resetStats() {
        lock.withLock {
            outstanding = []
            calls = []
            answers = []
            latencyList = []
            resyncs = []
        }
    }

    func latencies() -> [UInt64] { lock.withLock { latencyList } }
    func callTimes() -> [UInt64] { lock.withLock { calls } }
    func resyncTimes() -> [UInt64] { lock.withLock { resyncs } }
    func answerTimes() -> [UInt64] { lock.withLock { answers } }
    func answered() -> Int { lock.withLock { answers.count } }

    func detach() {
        if let id = lock.withLock({ viewer }) { hub.detach(connectionId: id) }
    }
}

/// Feeds session X flat out, 4 KiB at a time (a pty read's most), recording each
/// `write`'s start and end.
private final class Feeder: @unchecked Sendable {
    private let hub: PaneStreamHub
    private let session: String
    private let capacity = 1 << 22
    private let starts: UnsafeMutablePointer<UInt64>
    private let ends: UnsafeMutablePointer<UInt64>
    private let lock = NSLock()
    private var count = 0
    private var running = true
    private let done = DispatchSemaphore(value: 0)
    static let chunk = 4096

    init(hub: PaneStreamHub, session: String) {
        self.hub = hub
        self.session = session
        starts = .allocate(capacity: capacity)
        ends = .allocate(capacity: capacity)
        let source = Rig.logLines(from: 0, count: 12_000)
        let thread = Thread { [self] in feed(source) }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        starts.deallocate()
        ends.deallocate()
    }

    private func feed(_ source: [UInt8]) {
        var offset = 0
        var index = 0
        while lock.withLock({ running }), index < capacity {
            if offset + Self.chunk > source.count { offset = 0 }
            let bytes = Array(source[offset..<(offset + Self.chunk)])
            offset += Self.chunk
            starts[index] = now()
            hub.write(session: session, bytes: bytes)
            ends[index] = now()
            index += 1
            lock.withLock { count = index }
        }
        done.signal()
    }

    /// The number of writes finished so far.
    func mark() -> Int { lock.withLock { count } }

    func spans(_ range: Range<Int>) -> [Span] {
        range.map { Span(start: starts[$0], end: ends[$0]) }
    }

    func rate(_ range: Range<Int>) -> String {
        guard range.count > 1 else { return "0" }
        let seconds = Double(ends[range.upperBound - 1] - starts[range.lowerBound]) / 1e9
        return String(format: "%.1f", Double(range.count * Self.chunk) / 1_048_576 / seconds)
    }

    func stop() {
        lock.withLock { running = false }
        done.wait()
    }
}

/// Waits for the delivery queue every half millisecond and records the longest wait
/// since the last `mark`: how long the queue was held by something else.
private final class QueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var longest: UInt64 = 0
    private var running = true
    private let done = DispatchSemaphore(value: 0)

    init(hub: PaneStreamHub) {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let start = now()
                hub.waitForPendingDeliveries()
                let waited = now() - start
                lock.withLock { longest = max(longest, waited) }
                usleep(500)
            }
            done.signal()
        }
    }

    func mark() { lock.withLock { longest = 0 } }
    func collectMax() -> UInt64 { lock.withLock { longest } }

    func stop() {
        lock.withLock { running = false }
        done.wait()
    }
}

/// A blocking Unix stream socket client.
private final class Socket: @unchecked Sendable {
    let fd: Int32

    init(connectingTo path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var suppress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
        }
    }

    /// Up to `max` bytes, waiting up to `timeout` for the first; nil on an end or a
    /// timeout.
    func read(max: Int, timeout: TimeInterval) -> [UInt8]? {
        var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&readable, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: max)
        let count = Darwin.read(fd, &buffer, max)
        guard count > 0 else { return nil }
        return Array(buffer[0..<count])
    }

    /// Whether the server has shut the socket down: a hang up, or a write that fails.
    func isHungUp() -> Bool {
        var probe = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&probe, 1, 0)
        if Int32(probe.revents) & (POLLHUP | POLLERR) != 0 { return true }
        var byte: UInt8 = 0
        return Darwin.write(fd, &byte, 1) < 0
    }

    func close() { Darwin.close(fd) }
}

/// Calls `body` every millisecond on a thread of its own until stopped.
private final class Sender: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var done: DispatchSemaphore?

    func start(_ body: @escaping @Sendable (Int) -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock {
            running = true
            done = semaphore
        }
        Thread.detachNewThread { [self] in
            var tick = 0
            while lock.withLock({ running }) {
                body(tick)
                tick += 1
                usleep(1_000)
            }
            semaphore.signal()
        }
    }

    func stop() {
        let semaphore: DispatchSemaphore? = lock.withLock {
            running = false
            let waiting = done
            done = nil
            return waiting
        }
        semaphore?.wait()
    }
}

private final class EndRecorder: @unchecked Sendable {
    let first = DispatchSemaphore(value: 0)
    let ended = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: TerminalEndReason?

    var reason: TerminalEndReason? { lock.withLock { stored } }

    func end(_ reason: TerminalEndReason) {
        lock.withLock { stored = reason }
        ended.signal()
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = "noEnd"
    var value: String { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}
