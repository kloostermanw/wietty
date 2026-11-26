import AppKit
import Foundation
import Testing
import WiettyCore
import WiettyShared
@testable import Wietty

// MARK: Fakes

/// The main queue, by hand: hops from a link's thread and the next main turn both land
/// here, in order, and run only when the test says so. Each item it runs is one turn.
///
/// Every enqueue and every host call takes a stamp from one counter, so a test can tell
/// whether the turn a surface was created in was put on the queue after a destroy (the
/// rule task 2 measured), not only whether it ran later.
private final class ManualMain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(stamp: Int, work: @MainActor () -> Void)] = []
    private var counter = 0
    /// When the item running now was put on the queue; 0 outside any item.
    private(set) var runningSince = 0

    /// The next stamp.
    func stamp() -> Int { lock.withLock { counter += 1; return counter } }

    func enqueue(_ work: @escaping @MainActor () -> Void) {
        let stamp = stamp()
        lock.withLock { items.append((stamp, work)) }
    }

    /// Runs the first item queued, as one turn. False when there was none.
    @MainActor @discardableResult
    func runOne() -> Bool {
        guard let item = lock.withLock({ items.isEmpty ? nil : items.removeFirst() }) else { return false }
        let outer = runningSince
        runningSince = item.stamp
        item.work()
        runningSince = outer
        return true
    }

    /// Runs items, those queued meanwhile too, until none is left.
    @MainActor
    func drain() {
        while runOne() {}
    }
}

/// Timers by hand: what is scheduled, when it is due, and whether it was cancelled.
@MainActor
private final class ManualTimers {
    final class Timer {
        let delay: TimeInterval
        let due: TimeInterval
        let work: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(delay: TimeInterval, due: TimeInterval, work: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.due = due
            self.work = work
        }
    }

    var now: TimeInterval = 1000
    private(set) var all: [Timer] = []

    var live: [Timer] { all.filter { !$0.cancelled && !$0.fired } }
    /// Live retry timers (a policy delay, at most 5 s).
    var retries: [Timer] { live.filter { $0.delay != RemotePane.attemptTimeout } }
    /// Live attempt timeouts.
    var watchdogs: [Timer] { live.filter { $0.delay == RemotePane.attemptTimeout } }

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> RemotePane.Cancel {
        let timer = Timer(delay: delay, due: now + delay, work: work)
        all.append(timer)
        return { timer.cancelled = true }
    }

    /// Moves the clock to the next timer that is due and fires it.
    func fireNext() {
        guard let next = live.min(by: { $0.due < $1.due }) else { return }
        now = max(now, next.due)
        next.fired = true
        next.work()
    }
}

/// A link the test drives on the calling thread, as a link's own thread would.
private final class FakeLink: TerminalStreamLink, @unchecked Sendable {
    let connection: RemoteConnection
    let session: String
    private let lock = NSLock()
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var started = 0
    private var stopped = 0

    init(connection: RemoteConnection, session: String) {
        self.connection = connection
        self.session = session
    }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }
    var starts: Int { lock.withLock { started } }
    var stops: Int { lock.withLock { stopped } }

    func start() { lock.withLock { started += 1 } }
    func stop() { lock.withLock { stopped += 1 } }
    func send(_ bytes: [UInt8]) {}
    func claim(cols: Int, rows: Int) {}

    func deliver(_ message: StreamMessage) { onMessage?(message) }
    func end(_ reason: TerminalEndReason) { onEnded?(reason) }
}

/// A bridge that starts every link it is given at once, as the real one does once its
/// helper is there, and records what the owner asks of it. It models the real bridge's
/// held claims: with `holdsClaimsUntilReset`, the end of the link that is the bridge's
/// holds every claim until `resetClaims()`, and a held claim is accepted but never sent.
/// The end of a link the bridge no longer has holds nothing.
private final class FakeBridge: ViewerBridging, @unchecked Sendable {
    let helperSocketPath: String
    private let lock = NSLock()
    private var linkList: [any TerminalStreamLink] = []
    private var stopCount = 0
    private var claimList: [[Int]] = []
    private var heldList: [[Int]] = []
    private var claimsHeld = false
    private var resets = 0
    private var holds = false
    private var gone: (@Sendable () -> Void)?
    private var beforeReconnectHook: (() -> Void)?

    init(path: String, link: any TerminalStreamLink) {
        helperSocketPath = path
        attach(link)
    }

    var links: [any TerminalStreamLink] { lock.withLock { linkList } }
    var stops: Int { lock.withLock { stopCount } }
    /// Claims sent to a link.
    var claims: [[Int]] { lock.withLock { claimList } }
    /// Claims accepted while held, never sent.
    var held: [[Int]] { lock.withLock { heldList } }
    var resetCount: Int { lock.withLock { resets } }

    /// Runs once, inside the next `reconnect(with:)`, before the link is swapped: what
    /// the old link's thread does at that moment.
    var beforeReconnect: (() -> Void)? {
        get { lock.withLock { beforeReconnectHook } }
        set { lock.withLock { beforeReconnectHook = newValue } }
    }

    var holdsClaimsUntilReset: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }
    var onHelperGone: (@Sendable () -> Void)? {
        get { lock.withLock { gone } }
        set { lock.withLock { gone = newValue } }
    }

    func claim(cols: Int, rows: Int) -> Bool {
        lock.withLock {
            guard stopCount == 0 else { return false }
            if claimsHeld { heldList.append([cols, rows]) } else { claimList.append([cols, rows]) }
            return true
        }
    }
    func resetClaims() {
        lock.withLock {
            resets += 1
            claimsHeld = false
            heldList = []
        }
    }
    func reconnect(with link: any TerminalStreamLink) {
        let hook = lock.withLock { () -> (() -> Void)? in
            defer { beforeReconnectHook = nil }
            return beforeReconnectHook
        }
        hook?()
        let old = lock.withLock { linkList.last }
        old?.stop()
        attach(link)
    }
    func stop() {
        let current = lock.withLock { () -> (any TerminalStreamLink)? in
            stopCount += 1
            return stopCount == 1 ? linkList.last : nil
        }
        current?.stop()
    }

    /// The helper went away by itself.
    func helperWentAway() { onHelperGone?() }

    private func attach(_ link: any TerminalStreamLink) {
        lock.withLock { linkList.append(link) }
        // As the real bridge: its own handlers, then the start.
        link.onMessage = { _ in }
        link.onEnded = { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.lock.withLock {
                if self.holds, self.linkList.last === link { self.claimsHeld = true }
            }
        }
        link.start()
    }
}

/// The host, as far as a remote pane uses it.
@MainActor
private final class FakeViewerHost: ViewerSurfaceHosting {
    enum Call: Equatable {
        /// `queuedAt`: when the turn that created it was put on the main queue.
        case create(String, queuedAt: Int)
        /// `at`: the stamp of the destroy itself.
        case destroy(String, at: Int)
    }

    let main: ManualMain
    var failCreate = false
    private(set) var calls: [Call] = []
    private(set) var commands: [String: String] = [:]
    private(set) var grids: [String: OwnPaneGrid] = [:]
    private(set) var imposed: [(TerminalSize?, String)] = []
    private var views: [String: NSView] = [:]

    init(main: ManualMain) { self.main = main }

    var created: [String] { calls.compactMap { if case .create(let id, _) = $0 { id } else { nil } } }
    var destroyed: [String] { calls.compactMap { if case .destroy(let id, _) = $0 { id } else { nil } } }

    func createViewerSurface(id: String, command: String, grid: OwnPaneGrid?) throws {
        if failCreate { throw SurfaceHostError.surfaceFailed }
        calls.append(.create(id, queuedAt: main.runningSince))
        commands[id] = command
        grids[id] = grid
        views[id] = NSView()
    }
    func destroySurface(id: String) {
        calls.append(.destroy(id, at: main.stamp()))
        grids[id] = nil
        views[id] = nil
    }
    func impose(grid: TerminalSize?, on id: String) { imposed.append((grid, id)) }
    func view(id: String) -> NSView? { views[id] }
}

/// What the store holds and what the factories made, reached by the pane's closures.
@MainActor
private final class Made {
    var connections: [RemoteConnection] = []
    var links: [FakeLink] = []
    var bridges: [FakeBridge] = []
    var failBridge = false
}

/// Everything a pane is given, by hand, and what it made.
@MainActor
private final class Rig {
    let main = ManualMain()
    let timers = ManualTimers()
    let host: FakeViewerHost
    let made = Made()
    let panes: RemotePanes

    static let connectionId = UUID()

    var connections: [RemoteConnection] {
        get { made.connections }
        set { made.connections = newValue }
    }
    var links: [FakeLink] { made.links }
    var bridges: [FakeBridge] { made.bridges }
    var failBridge: Bool {
        get { made.failBridge }
        set { made.failBridge = newValue }
    }

    init() {
        host = FakeViewerHost(main: main)
        made.connections = [RemoteConnection(id: Self.connectionId, name: "Studio", host: "studio.local",
                                             port: 7777, token: "secret-1")]
        let made = self.made
        let main = self.main
        let timers = self.timers
        panes = RemotePanes(dependencies: RemotePane.Dependencies(
            host: host,
            helperPath: "/Apps/Wietty 2.app/wietty-pty",
            connection: { id in made.connections.first { $0.id == id } },
            makeLink: { connection, session in
                let link = FakeLink(connection: connection, session: session)
                made.links.append(link)
                return link
            },
            makeBridge: { link in
                if made.failBridge { throw SurfaceHostError.surfaceFailed }
                let bridge = FakeBridge(path: "/tmp/wty-\(made.bridges.count).sock", link: link)
                made.bridges.append(bridge)
                return bridge
            },
            now: { timers.now },
            schedule: { delay, work in timers.schedule(delay, work) },
            toMain: { work in main.enqueue(work) },
            nextTurn: { work in main.enqueue(work) }))
    }

    var ref: RemoteSessionRef { RemoteSessionRef(connectionId: Self.connectionId, sessionId: "s1") }

    /// A pane opened and shown: its surface created on the next turn.
    func shown(_ ref: RemoteSessionRef? = nil) -> RemotePane {
        let pane = panes.open(ref ?? self.ref)
        main.drain()
        return pane
    }

    /// The link the pane made last, as the bridge has it.
    var link: FakeLink { links.last! }
    var bridge: FakeBridge { bridges.last! }

    /// The current link delivers its snapshot and the hop runs.
    func snapshot() {
        link.deliver(.snapshot([0x1B, 0x63]))
        main.drain()
    }

    func lose() {
        link.end(.connectionLost)
        main.drain()
    }
}

// MARK: Tests

/// The owner of a pane showing a terminal of another Mac: its surface, its bridge,
/// each link and the reconnect policy, with every thread hop, turn and timer by hand.
@MainActor
@Suite struct RemotePaneTests {
    @Test func theSurfaceIsMadeOnTheTurnAfterOpenWithAViewerIdAndTheHelpersCommand() throws {
        let rig = Rig()
        let pane = rig.panes.open(rig.ref)
        #expect(rig.host.created.isEmpty)
        #expect(rig.links.isEmpty)
        #expect(pane.state == .connecting)
        rig.main.drain()

        let id = try #require(rig.host.created.first)
        #expect(rig.host.created.count == 1)
        #expect(id.hasPrefix("rv:\(Rig.connectionId.uuidString):s1:"))
        #expect(pane.surfaceId == id)
        #expect(pane.surfaceView != nil)
        #expect(rig.host.commands[id] == PaneBridges.command(helper: "/Apps/Wietty 2.app/wietty-pty",
                                                             socket: rig.bridge.helperSocketPath))
        #expect(rig.bridge.holdsClaimsUntilReset)
        #expect(rig.links.count == 1)
        #expect(rig.link.session == "s1")
        #expect(rig.link.starts == 1)
        #expect(pane.state == .connecting)
    }

    @Test func everySurfaceGetsAnIdOfItsOwn() throws {
        let rig = Rig()
        _ = rig.shown()
        rig.panes.close(rig.ref)
        _ = rig.shown()
        #expect(rig.host.created.count == 2)
        #expect(Set(rig.host.created).count == 2)
    }

    @Test func aSnapshotMakesThePaneLive() {
        let rig = Rig()
        let pane = rig.shown()
        rig.link.deliver(.data([0x41]))
        rig.main.drain()
        #expect(pane.state == .connecting)
        rig.snapshot()
        #expect(pane.state == .live)
    }

    @Test func aLostLinkMakesANewLinkOnTheSameBridgeAndNoNewSurface() {
        let rig = Rig()
        let pane = rig.shown()
        rig.snapshot()
        rig.lose()
        #expect(pane.state == .reconnecting)
        // At once: no timer, a second link on the one bridge.
        #expect(rig.timers.retries.isEmpty)
        #expect(rig.bridges.count == 1)
        #expect(rig.bridge.links.count == 2)
        #expect(rig.links[1].starts == 1)
        #expect(rig.host.created.count == 1)
        #expect(rig.host.destroyed.isEmpty)
        // The grid's count started over through the bridge.
        #expect(rig.bridge.resetCount == 1)

        // The second loss waits 0.25 s.
        rig.lose()
        #expect(rig.bridge.links.count == 2)
        #expect(rig.timers.retries.map(\.due) == [rig.timers.now + 0.25])
        rig.timers.fireNext()
        #expect(rig.bridge.links.count == 3)
        #expect(rig.host.created.count == 1)
        rig.snapshot()
        #expect(pane.state == .live)
    }

    @Test func eachLinkIsBuiltFromTheConnectionTheStoreHoldsThen() {
        let rig = Rig()
        _ = rig.shown()
        #expect(rig.link.connection.token == "secret-1")
        rig.connections[0].token = "secret-2"
        rig.connections[0].host = "studio-2.local"
        rig.lose()
        #expect(rig.link.connection.token == "secret-2")
        #expect(rig.link.connection.host == "studio-2.local")
    }

    @Test func aConnectionGoneFromTheStoreEndsInRefused() throws {
        let rig = Rig()
        let pane = rig.shown()
        let id = try #require(pane.surfaceId)
        rig.connections = []
        rig.lose()
        #expect(pane.state == .refused("Connection removed"))
        #expect(rig.links.count == 1)
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed == [id])
        #expect(pane.surfaceId == nil)
    }

    @Test func aConnectionGoneBeforeTheSurfaceIsMadeMakesNoSurface() {
        let rig = Rig()
        rig.connections = []
        let pane = rig.shown()
        #expect(pane.state == .refused("Connection removed"))
        #expect(rig.host.calls.isEmpty)
        #expect(rig.bridges.isEmpty)
    }

    @Test func anEndedSessionKeepsTheBridgeAndTheSurface() {
        let rig = Rig()
        let pane = rig.shown()
        rig.snapshot()
        rig.link.end(.sessionEnded)
        rig.main.drain()
        #expect(pane.state == .ended)
        #expect(rig.bridge.stops == 0)
        #expect(rig.host.destroyed.isEmpty)
        #expect(pane.surfaceId != nil)
        #expect(rig.timers.live.isEmpty)
        #expect(rig.bridge.links.count == 1)
        // The button does nothing now.
        pane.reconnectPressed()
        #expect(rig.bridge.links.count == 1)
        // Closing it still stops and destroys.
        rig.panes.close(rig.ref)
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed.count == 1)
    }

    @Test func aRefusalDestroysTheSurfaceAtOnce() throws {
        let rig = Rig()
        let pane = rig.shown()
        let id = try #require(pane.surfaceId)
        rig.link.end(.refused(code: "busy", message: "No\u{1B}[31m more"))
        rig.main.drain()
        #expect(pane.state == .refused("No[31m more"))
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed == [id])
        #expect(pane.surfaceId == nil)
        #expect(rig.links.count == 1)
        // Closing it later does not destroy again.
        rig.panes.close(rig.ref)
        #expect(rig.host.destroyed == [id])
    }

    @Test func aServerTooOldIsRefusedWithItsText() {
        let rig = Rig()
        let pane = rig.shown()
        rig.link.end(.serverTooOld)
        rig.main.drain()
        #expect(pane.state == .refused(RemoteReconnectPolicy.tooOldText))
        #expect(rig.host.destroyed.count == 1)
    }

    @Test func aSurfaceThatCannotBeMadeIsAFailureToShow() {
        let rig = Rig()
        rig.host.failCreate = true
        let pane = rig.shown()
        guard case .refused = pane.state else {
            Issue.record("state is \(pane.state)")
            return
        }
        #expect(rig.bridge.stops == 1)
        #expect(pane.surfaceId == nil)
    }

    @Test func aBridgeThatCannotBeMadeIsAFailureToShow() {
        let rig = Rig()
        rig.failBridge = true
        let pane = rig.shown()
        guard case .refused = pane.state else {
            Issue.record("state is \(pane.state)")
            return
        }
        #expect(rig.host.calls.isEmpty)
    }

    @Test func closeDuringAPendingRetryCancelsIt() {
        let rig = Rig()
        _ = rig.shown()
        rig.lose()
        rig.lose()
        #expect(rig.timers.retries.count == 1)
        let timer = rig.timers.retries[0]
        rig.panes.close(rig.ref)
        #expect(timer.cancelled)
        // Fired anyway, as a timer already on its way would be: nothing comes of it.
        timer.work()
        #expect(rig.bridge.links.count == 2)
        #expect(rig.links.count == 2)
    }

    @Test func nothingIsCalledAfterClose() throws {
        let rig = Rig()
        let pane = rig.shown()
        let link = rig.link
        let bridge = rig.bridge
        let grid = try #require(rig.host.grids[pane.surfaceId!])
        rig.panes.close(rig.ref)
        #expect(bridge.stops == 1)
        #expect(link.stops == 1)
        #expect(rig.host.destroyed.count == 1)
        let calls = rig.host.calls
        let imposed = rig.host.imposed.count
        let timers = rig.timers.all.count
        #expect(rig.timers.live.isEmpty)

        // Whatever the link's thread still had on its way.
        link.deliver(.snapshot([0x1B, 0x63]))
        link.deliver(.resize(cols: 100, rows: 30, own: false))
        link.end(.connectionLost)
        bridge.helperWentAway()
        rig.main.drain()
        pane.reconnectPressed()
        grid.paneChanged(ownGrid: TerminalSize(cols: 80, rows: 24))
        grid.userActed()

        #expect(pane.state == .connecting)
        #expect(rig.links.count == 1)
        #expect(bridge.links.count == 1)
        #expect(bridge.claims.isEmpty)
        #expect(rig.timers.all.count == timers)
        #expect(rig.timers.live.isEmpty)
        #expect(rig.host.calls == calls)
        #expect(rig.host.imposed.count == imposed)
        #expect(bridge.stops == 1)
    }

    @Test func aPaneClosedBeforeItsTurnMakesNothing() {
        let rig = Rig()
        let pane = rig.panes.open(rig.ref)
        rig.panes.close(rig.ref)
        rig.main.drain()
        #expect(rig.host.calls.isEmpty)
        #expect(rig.bridges.isEmpty)
        #expect(rig.links.isEmpty)
        #expect(pane.state == .connecting)
    }

    @Test func aResizeIsImposedOnTheSurfaceAfterTheHop() throws {
        let rig = Rig()
        let pane = rig.shown()
        let id = try #require(pane.surfaceId)
        rig.link.deliver(.resize(cols: 100, rows: 30, own: false))
        #expect(!rig.host.imposed.contains { $0.0 == TerminalSize(cols: 100, rows: 30) })
        rig.main.drain()
        #expect(rig.host.imposed.contains { $0.0 == TerminalSize(cols: 100, rows: 30) && $0.1 == id })
    }

    @Test func showingClaimsNothingAndAUserActionClaimsThroughTheBridge() throws {
        let rig = Rig()
        let pane = rig.shown()
        let grid = try #require(rig.host.grids[pane.surfaceId!])
        grid.paneChanged(ownGrid: TerminalSize(cols: 80, rows: 24))
        #expect(rig.bridge.claims.isEmpty)
        grid.userActed()
        #expect(rig.bridge.claims == [[80, 24]])
    }

    @Test func theButtonWhileReconnectingAttemptsNow() {
        let rig = Rig()
        let pane = rig.shown()
        rig.lose()
        rig.lose()
        let timer = rig.timers.retries[0]
        pane.reconnectPressed()
        #expect(timer.cancelled)
        #expect(rig.bridge.links.count == 3)
        #expect(pane.state == .reconnecting)
    }

    @Test func theButtonWhileWaitingAttemptsNowAndReconnects() {
        let rig = Rig()
        let pane = rig.shown()
        rig.lose()
        rig.timers.now += 200
        rig.lose()
        #expect(pane.state == .waiting)
        #expect(rig.timers.retries.isEmpty)
        let links = rig.bridge.links.count
        pane.reconnectPressed()
        #expect(rig.bridge.links.count == links + 1)
        #expect(pane.state == .reconnecting)
        rig.snapshot()
        #expect(pane.state == .live)
    }

    /// A press while an attempt is out replaces that link: what the replaced link still
    /// delivers is not taken for the new one's.
    @Test func whatAReplacedLinkStillDeliversIsIgnored() {
        let rig = Rig()
        let pane = rig.shown()
        rig.lose()
        let replaced = rig.link
        let resets = rig.bridge.resetCount
        pane.reconnectPressed()
        #expect(rig.bridge.links.count == 3)
        // No end preceded this reconnect, so the grid's count started over here.
        #expect(rig.bridge.resetCount == resets + 1)
        replaced.deliver(.snapshot([0x1B, 0x63]))
        replaced.end(.connectionLost)
        rig.main.drain()
        #expect(pane.state == .reconnecting)
        #expect(rig.bridge.links.count == 3)
        rig.snapshot()
        #expect(pane.state == .live)
    }

    @Test func aHelperThatWentAwayEndsThePane() {
        let rig = Rig()
        let pane = rig.shown()
        rig.bridge.helperWentAway()
        #expect(rig.bridge.stops == 0)
        rig.main.drain()
        guard case .refused = pane.state else {
            Issue.record("state is \(pane.state)")
            return
        }
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed.count == 1)
    }

    // MARK: Fix round 1

    /// The first link (or a helper that never connects, which is the same to the pane:
    /// no snapshot) takes longer than 15 s: it counts as lost and is retired.
    @Test func aFirstLinkWithNoSnapshotWithin15SecondsCountsAsLost() throws {
        let rig = Rig()
        let pane = rig.shown()
        let first = rig.link
        #expect(rig.timers.watchdogs.map(\.due) == [rig.timers.now + 15])
        rig.timers.fireNext()
        #expect(pane.state == .reconnecting)
        // Retired as a replaced link is, then a new attempt at once.
        #expect(first.stops == 1)
        #expect(rig.bridge.links.count == 3)
        #expect(rig.bridge.links[1] is InertLink)
        #expect(rig.links.count == 2)
        #expect(rig.host.created.count == 1)
        #expect(rig.timers.watchdogs.count == 1)
        // What the retired link still reports is not taken for the new one's.
        first.deliver(.snapshot([0x1B, 0x63]))
        first.end(.connectionLost)
        rig.main.drain()
        #expect(pane.state == .reconnecting)
        #expect(rig.links.count == 2)
        rig.snapshot()
        #expect(pane.state == .live)
    }

    @Test func aSnapshotCancelsTheTimeout() {
        let rig = Rig()
        let pane = rig.shown()
        let watchdog = rig.timers.watchdogs[0]
        rig.snapshot()
        #expect(watchdog.cancelled)
        // A late fire of it does nothing.
        watchdog.work()
        #expect(pane.state == .live)
        #expect(rig.bridge.links.count == 1)
    }

    @Test func anEndCancelsTheTimeoutAndTheNextLinkHasItsOwn() {
        let rig = Rig()
        _ = rig.shown()
        let first = rig.timers.watchdogs[0]
        rig.lose()
        #expect(first.cancelled)
        #expect(rig.timers.watchdogs.count == 1)
        #expect(rig.timers.watchdogs[0] !== first)
        first.work()
        #expect(rig.bridge.links.count == 2)
    }

    @Test func aReplacementCancelsTheTimeoutOfTheReplacedLink() {
        let rig = Rig()
        let pane = rig.shown()
        rig.lose()
        let replaced = rig.timers.watchdogs[0]
        pane.reconnectPressed()
        #expect(replaced.cancelled)
        #expect(rig.timers.watchdogs.count == 1)
        replaced.work()
        #expect(rig.bridge.links.count == 3)
        #expect(pane.state == .reconnecting)
    }

    @Test func closeCancelsTheTimeout() {
        let rig = Rig()
        let pane = rig.shown()
        let watchdog = rig.timers.watchdogs[0]
        rig.panes.close(rig.ref)
        #expect(watchdog.cancelled)
        let calls = rig.host.calls
        watchdog.work()
        #expect(rig.bridge.links.count == 1)
        #expect(rig.host.calls == calls)
        #expect(pane.state == .connecting)
    }

    /// The last attempt before the 2 minutes hangs: its timeout ends the automatic phase,
    /// the hung link is retired, and the button still makes a link whose claims flow.
    @Test func aHungLastAttemptEndsInWaitingAndTheButtonStillWorks() throws {
        let rig = Rig()
        let pane = rig.shown()
        let grid = try #require(rig.host.grids[pane.surfaceId!])
        rig.snapshot()
        rig.lose()                       // at 1000: a new phase, link 2 at once
        rig.timers.now = 1119
        rig.lose()                       // 0.25 s: due 1119.25, inside the 2 minutes
        rig.timers.fireNext()            // link 3, which never delivers
        let hung = rig.link
        #expect(rig.links.count == 3)
        rig.timers.fireNext()            // its timeout, at 1134.25
        #expect(pane.state == .waiting)
        #expect(hung.stops == 1)
        #expect(rig.bridge.links.last is InertLink)
        #expect(rig.timers.live.isEmpty)
        hung.deliver(.snapshot([0x1B, 0x63]))
        rig.main.drain()
        #expect(pane.state == .waiting)

        let resets = rig.bridge.resetCount
        pane.reconnectPressed()
        #expect(rig.links.count == 4)
        // The inert link was out: the grid's count starts over after the replacement.
        #expect(rig.bridge.resetCount == resets + 1)
        grid.paneChanged(ownGrid: TerminalSize(cols: 80, rows: 24))
        grid.userActed()
        #expect(rig.bridge.claims == [[80, 24]])
    }

    /// The race of a replacement: the old link ends after the grid was reset and before
    /// the bridge has the new link. The bridge then holds claims, and the reset after
    /// the reconnect lets them flow again.
    @Test func anOldLinkEndingDuringAReplacementLeavesClaimsFlowing() throws {
        let rig = Rig()
        let pane = rig.shown()
        let grid = try #require(rig.host.grids[pane.surfaceId!])
        grid.paneChanged(ownGrid: TerminalSize(cols: 80, rows: 24))
        rig.lose()
        let old = rig.link
        rig.bridge.beforeReconnect = { old.end(.connectionLost) }
        pane.reconnectPressed()
        rig.main.drain()
        #expect(pane.state == .reconnecting)
        grid.userActed()
        #expect(rig.bridge.claims == [[80, 24]])
        #expect(rig.bridge.held.isEmpty)
    }

    @Test func theButtonWithNoLinkOutDoesNotResetTheGrid() {
        let rig = Rig()
        let pane = rig.shown()
        rig.lose()
        rig.lose()                        // link 2 ended, a retry pending: nothing out
        var resets = rig.bridge.resetCount
        pane.reconnectPressed()
        #expect(rig.bridge.resetCount == resets)
        rig.timers.now += 200
        rig.lose()                        // waiting: nothing out
        #expect(pane.state == .waiting)
        resets = rig.bridge.resetCount
        pane.reconnectPressed()
        #expect(rig.bridge.resetCount == resets)
    }

    @Test func anEndedPaneWhoseHelperWentAwayKeepsItsSurface() {
        let rig = Rig()
        let pane = rig.shown()
        rig.snapshot()
        rig.link.end(.sessionEnded)
        rig.main.drain()
        rig.bridge.helperWentAway()
        rig.main.drain()
        #expect(pane.state == .ended)
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed.isEmpty)
        #expect(pane.surfaceId != nil)
        rig.panes.close(rig.ref)
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed.count == 1)
    }

    /// SwiftUI may run a new view's appear before the old one's disappear for one ref.
    @Test func opensAndClosesAreCountedPerSession() {
        let rig = Rig()
        let first = rig.panes.open(rig.ref)
        let second = rig.panes.open(rig.ref)
        #expect(first === second)
        rig.main.drain()
        #expect(rig.host.created.count == 1)
        #expect(rig.panes.opens(of: rig.ref) == 2)

        rig.panes.close(rig.ref)
        #expect(rig.host.destroyed.isEmpty)
        #expect(rig.panes.pane(for: rig.ref) === first)
        #expect(first.surfaceId != nil)

        rig.panes.close(rig.ref)
        #expect(rig.host.destroyed.count == 1)
        #expect(rig.panes.pane(for: rig.ref) == nil)
        // A further close is nothing.
        rig.panes.close(rig.ref)
        #expect(rig.host.destroyed.count == 1)

        // The closed pane never comes back.
        let third = rig.panes.open(rig.ref)
        #expect(third !== first)
        rig.main.drain()
        #expect(rig.host.created.count == 2)
        #expect(third.surfaceId != nil)
    }

    @Test func closeAllIgnoresTheCounts() {
        let rig = Rig()
        _ = rig.panes.open(rig.ref)
        _ = rig.panes.open(rig.ref)
        rig.main.drain()
        rig.panes.closeAll()
        #expect(rig.panes.count == 0)
        #expect(rig.host.destroyed.count == 1)
        #expect(rig.bridge.stops == 1)
    }

    /// At quit a view may still appear after `closeAll`: its open gets a pane that
    /// makes nothing, is not kept, and whose close is nothing.
    @Test func nothingOpensAfterCloseAll() {
        let rig = Rig()
        rig.panes.closeAll()
        let late = rig.panes.open(rig.ref)
        rig.main.drain()
        #expect(rig.panes.count == 0)
        #expect(rig.panes.opens(of: rig.ref) == 0)
        #expect(rig.host.created.isEmpty)
        #expect(late.surfaceId == nil)
        #expect(late.state == .connecting)
        late.reconnectPressed()
        rig.panes.close(rig.ref)
        rig.main.drain()
        #expect(rig.host.created.isEmpty)
        #expect(rig.host.destroyed.isEmpty)
        #expect(rig.bridges.isEmpty)
        #expect(rig.links.isEmpty)
    }

    // MARK: The registry and the turn between a destroy and a create

    @Test func openingTheSameSessionTwiceGivesTheSamePane() {
        let rig = Rig()
        let first = rig.panes.open(rig.ref)
        let second = rig.panes.open(rig.ref)
        #expect(first === second)
        rig.main.drain()
        #expect(rig.host.created.count == 1)
    }

    /// The create of `id` ran in a turn put on the main queue after the destroy of
    /// `destroyed`.
    private func createdAfter(_ rig: Rig, destroyed: String, created prefix: String) -> Bool {
        var destroyAt: Int?
        var createQueuedAt: Int?
        for call in rig.host.calls {
            switch call {
            case .destroy(let id, let at) where id == destroyed: destroyAt = at
            case .create(let id, let queuedAt) where id.hasPrefix(prefix): createQueuedAt = queuedAt
            default: break
            }
        }
        guard let destroyAt, let createQueuedAt else {
            Issue.record("calls are \(rig.host.calls)")
            return false
        }
        return createQueuedAt > destroyAt
    }

    /// One pane closes and another opens in the same turn: the new surface is created
    /// in a turn put on the queue after the old one's destroy.
    @Test func aSurfaceIsNeverCreatedInTheTurnOfADestroy() throws {
        let rig = Rig()
        let first = rig.shown()
        let firstId = try #require(first.surfaceId)
        let other = RemoteSessionRef(connectionId: Rig.connectionId, sessionId: "s2")
        // One turn: close the first and open the second.
        rig.main.enqueue { [rig] in
            rig.panes.close(rig.ref)
            _ = rig.panes.open(other)
            #expect(rig.host.created.count == 1)
        }
        rig.main.drain()
        #expect(rig.host.created.count == 2)
        #expect(createdAfter(rig, destroyed: firstId, created: "rv:\(Rig.connectionId.uuidString):s2:"))
    }

    /// A destroy that runs after the create's turn was put on the queue, but before that
    /// turn runs, puts the create off to a turn queued after the destroy.
    @Test func aDestroyBetweenTheOpenAndItsTurnPutsTheCreateOff() throws {
        let rig = Rig()
        let first = rig.shown()
        let firstId = try #require(first.surfaceId)
        // On the first link's thread: a refusal, whose hop is queued now.
        rig.link.end(.refused(code: "busy", message: "busy"))
        // Then the second pane opens: its create's turn is queued behind that hop.
        let other = RemoteSessionRef(connectionId: Rig.connectionId, sessionId: "s2")
        _ = rig.panes.open(other)
        rig.main.drain()
        #expect(rig.host.destroyed == [firstId])
        #expect(rig.host.created.count == 2)
        #expect(createdAfter(rig, destroyed: firstId, created: "rv:\(Rig.connectionId.uuidString):s2:"))
    }

    @Test func closeAllClosesEveryPane() {
        let rig = Rig()
        let first = rig.shown()
        let other = RemoteSessionRef(connectionId: Rig.connectionId, sessionId: "s2")
        let second = rig.shown(other)
        #expect(rig.panes.count == 2)
        rig.panes.closeAll()
        #expect(rig.panes.count == 0)
        #expect(rig.host.destroyed.count == 2)
        #expect(rig.bridges.allSatisfy { $0.stops == 1 })
        #expect(first.surfaceId == nil)
        #expect(second.surfaceId == nil)
    }
}

/// `ObservedLink` with the real `TerminalBridge`: the bridge's handlers stay in charge
/// of the byte path, and the owner is told after them.
@Suite struct ObservedLinkTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.withLock { list } }
        func add(_ event: String) { lock.withLock { list.append(event) } }
    }

    @Test func theBridgeWritesTheSnapshotBeforeTheOwnerHearsOfItAndOnlyTheFirstIsReported() throws {
        let events = Events()
        let inner = FakeLink(connection: RemoteConnection(id: UUID(), name: "n", host: "h", port: 1, token: "t"),
                             session: "s")
        let link = ObservedLink(inner) { event in
            switch event {
            case .snapshot: events.add("snapshot")
            case let .resize(size, own): events.add("resize \(size.cols)x\(size.rows) \(own)")
            case .ended(let reason): events.add("ended \(reason)")
            }
        }
        let bridge = try TerminalBridge(helperSocketPath: shortSocketPath("ol"), link: link)
        defer { bridge.stop() }
        bridge.holdsClaimsUntilReset = true
        bridge.onResize = { _, _, _ in events.add("bridge resize") }
        bridge.onEnded = { _ in events.add("bridge ended") }
        let helper = try UnixTestSocket(connectingTo: bridge.helperSocketPath)
        defer { helper.close() }
        #expect(waitUntil { inner.starts == 1 })

        inner.deliver(.snapshot([0x1B, 0x63, 0x41]))
        // Delivered on this thread: the bridge's write to the helper has returned.
        #expect(events.all == ["snapshot"])
        #expect(helper.read(3) == [0x1B, 0x63, 0x41])
        inner.deliver(.data([0x42]))
        inner.deliver(.snapshot([0x43]))
        inner.deliver(.resize(cols: 90, rows: 20, own: true))
        inner.end(.connectionLost)
        #expect(helper.read(2) == [0x42, 0x43])
        #expect(events.all == ["snapshot", "bridge resize", "resize 90x20 true",
                               "bridge ended", "ended connectionLost"])
    }

    @Test func startAndStopReachTheLinkInside() {
        let inner = FakeLink(connection: RemoteConnection(id: UUID(), name: "n", host: "h", port: 1, token: "t"),
                             session: "s")
        let link = ObservedLink(inner) { _ in }
        link.start()
        link.stop()
        #expect(inner.starts == 1)
        #expect(inner.stops == 1)
    }
}

/// The app's own dependencies (`RemotePane.Dependencies.app`), as far as they go without
/// a real surface: the store, the real bridge on a real socket, and the main queue's
/// hops and timers. The host is the fake one; nothing connects as the helper, so no
/// link is ever started and nothing reaches the network.
@MainActor
@Suite struct RemotePaneAppDependenciesTests {
    private final class MemorySecrets: SecretStore {
        private var secrets: [String: String] = [:]
        func secret(for key: String) -> String? { secrets[key] }
        func setSecret(_ value: String, for key: String) { secrets[key] = value }
        func removeSecret(for key: String) { secrets[key] = nil }
    }

    private final class Box { var events: [String] = [] }

    private let connection = RemoteConnection(id: UUID(), name: "Studio", host: "127.0.0.1",
                                              port: 9, token: "not-a-token")

    private func store() -> RemoteConnectionsStore {
        let store = RemoteConnectionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                           secretStore: MemorySecrets())
        store.add(connection)
        return store
    }

    /// Lets the main queue run until `condition` holds or 5 s pass.
    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    @Test func aConnectionRemovedFromTheStoreBeforeTheShowIsRefused() async {
        let store = store()
        let host = FakeViewerHost(main: ManualMain())
        let panes = RemotePanes(dependencies: .app(host: host, helperPath: "/usr/bin/false", connections: store))
        store.remove(id: connection.id)
        let pane = panes.open(RemoteSessionRef(connectionId: connection.id, sessionId: "s1"))
        #expect(pane.state == .connecting)
        #expect(await until { pane.state != .connecting })
        #expect(pane.state == .refused("Connection removed"))
        #expect(host.calls.isEmpty)
    }

    @Test func aShownPaneListensOnARealSocketAndCloseRemovesIt() async throws {
        let store = store()
        let host = FakeViewerHost(main: ManualMain())
        let panes = RemotePanes(dependencies: .app(host: host, helperPath: "/usr/bin/false", connections: store))
        let ref = RemoteSessionRef(connectionId: connection.id, sessionId: "s1")
        let pane = panes.open(ref)
        #expect(await until { pane.surfaceId != nil })
        let id = try #require(pane.surfaceId)
        let command = try #require(host.commands[id])
        let parts = command.components(separatedBy: "' '")
        #expect(parts.count == 2)
        let socket = String(parts[1].dropLast())
        #expect(socket.hasSuffix(".sock"))
        #expect((socket as NSString).lastPathComponent.hasPrefix("wty-\(getpid())-"))
        #expect(FileManager.default.fileExists(atPath: socket))
        panes.close(ref)
        #expect(!FileManager.default.fileExists(atPath: socket))
        #expect(host.destroyed == [id])
    }

    @Test func theTimerRunsOnTheMainQueueAndACancelledOneNeverDoes() async {
        let dependencies = RemotePane.Dependencies.app(host: FakeViewerHost(main: ManualMain()),
                                                       helperPath: "/usr/bin/false",
                                                       connections: store())
        let box = Box()
        let cancel = dependencies.schedule(0.01) { box.events.append("cancelled") }
        cancel()
        // A later timer on the same queue: by the time it runs, the cancelled one's
        // deadline has passed.
        _ = dependencies.schedule(0.05) { box.events.append("later") }
        #expect(await until { !box.events.isEmpty })
        #expect(box.events == ["later"])
    }
}
