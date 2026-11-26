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

    /// Signalled on every enqueue, so a test waiting for a hop from another thread
    /// waits for it rather than for a time.
    private let arrived = DispatchSemaphore(value: 0)

    private var hopGate: DispatchSemaphore?

    /// The next hop from a thread other than the main one waits, once it is queued, until
    /// `gate` is signalled (five seconds at most): the link's thread stays inside its
    /// `observe` while the main actor runs that hop and what follows it.
    func holdNextHop(until gate: DispatchSemaphore) {
        lock.withLock { hopGate = gate }
    }

    func enqueue(_ work: @escaping @MainActor () -> Void) {
        let stamp = stamp()
        let gate = lock.withLock { () -> DispatchSemaphore? in
            items.append((stamp, work))
            guard !Thread.isMainThread else { return nil }
            defer { hopGate = nil }
            return hopGate
        }
        arrived.signal()
        _ = gate?.wait(timeout: .now() + 5)
    }

    /// Runs turns, waiting for hops from other threads, until `done` holds (then the
    /// turns queued by then too), or five seconds pass. Whether `done` held.
    @MainActor @discardableResult
    func run(until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            drain()
            if done() { drain(); return true }
            _ = arrived.wait(timeout: .now() + .milliseconds(10))
        }
        return done()
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

    /// Fires `timer` now, whatever is due before it.
    func fire(_ timer: Timer) {
        guard !timer.cancelled, !timer.fired else { return }
        now = max(now, timer.due)
        timer.fired = true
        timer.work()
    }

    /// Live timers of `RemotePane.snapshotHoldLimit` (1 s). Only the hold tests read
    /// it, and they make no retry of that length. A size query's expiry
    /// (`RemotePane.sizeQueryExpiry`) has that length too: a test that makes one tells
    /// them apart by when they were made (`made(since:)`).
    var holdLimits: [Timer] { live.filter { $0.delay == RemotePane.snapshotHoldLimit } }

    /// Every 1 s timer made so far, live or not: one per hold, one per expiry.
    var secondTimersMade: Int { all.filter { $0.delay == RemotePane.snapshotHoldLimit }.count }

    /// Live timers of `delay` made after the first `count` timers.
    func made(since count: Int, delay: TimeInterval) -> [Timer] {
        all[count...].filter { !$0.cancelled && !$0.fired && $0.delay == delay }
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

    /// Held for each callback; `stop()` waits for it, as the real link's does.
    private let callbackLock = NSLock()
    private var callbackThread: Thread?
    private var stopWaitedTooLong = false
    /// A `stop()` that waited five seconds for a running callback: a deadlock.
    var stopTimedOut: Bool { lock.withLock { stopWaitedTooLong } }

    func start() { lock.withLock { started += 1 } }
    private var stopHook: (() -> Void)?
    /// Runs in the next `stop()` not called from inside a callback, before it waits for
    /// the running callback: what may happen on the link's thread from then on.
    var beforeStopWaits: (() -> Void)? {
        get { lock.withLock { stopHook } }
        set { lock.withLock { stopHook = newValue } }
    }

    /// Waits for a running callback, unless called from inside it, as the real link.
    func stop() {
        let (inside, hook) = lock.withLock { () -> (Bool, (() -> Void)?) in
            stopped += 1
            defer { stopHook = nil }
            return (callbackThread === Thread.current, stopHook)
        }
        guard !inside else { return }
        hook?()
        if callbackLock.lock(before: Date().addingTimeInterval(5)) {
            callbackLock.unlock()
        } else {
            lock.withLock { stopWaitedTooLong = true }
        }
    }
    private var input: [UInt8] = []
    /// Every byte sent to the other Mac through this link.
    var sentBytes: [UInt8] { lock.withLock { input } }
    func send(_ bytes: [UInt8]) { lock.withLock { input += bytes } }
    func claim(cols: Int, rows: Int) {}

    func deliver(_ message: StreamMessage) { inCallback { onMessage?(message) } }
    func end(_ reason: TerminalEndReason) { inCallback { onEnded?(reason) } }

    private func inCallback(_ body: () -> Void) {
        callbackLock.lock()
        lock.withLock { callbackThread = Thread.current }
        body()
        lock.withLock { callbackThread = nil }
        callbackLock.unlock()
    }
}

/// A bridge that records what the owner asks of it. As the real one, it starts a link
/// only once its helper is there: the link it holds when the helper connects, and every
/// later one as it is given. Made with `helperConnected` (the default) the helper is
/// there from the start, so every link starts at once. It models the real bridge's
/// held claims: with `holdsClaimsUntilReset`, the end of the link that is the bridge's
/// holds every claim until `resetClaims()`, and a held claim is accepted but never sent.
/// The end of a link the bridge no longer has holds nothing.
///
/// As the real one, `reconnect` swaps the link first and stops the old one after (the
/// real bridge on a queue of its own, later), a message of a link that is no longer the
/// bridge's is dropped (never written, a size query included), each link is stopped once
/// at most, and a helper that goes away stops the current link before the owner is told.
private final class FakeBridge: ViewerBridging, @unchecked Sendable {
    let helperSocketPath: String
    private let lock = NSLock()
    private var linkList: [any TerminalStreamLink] = []
    private var helperThere: Bool
    private var messageList: [StreamMessage] = []
    /// Every message the bridge's link handed it, in order: what it writes to the helper
    /// (and the `resize`s it acts on).
    var messages: [StreamMessage] { lock.withLock { messageList } }
    private var droppedList: [StreamMessage] = []
    /// Messages a replaced link handed it, dropped.
    var dropped: [StreamMessage] { lock.withLock { droppedList } }
    private var stoppedLinks: Set<ObjectIdentifier> = []
    private var handingHook: (@Sendable (StreamMessage) -> Void)?
    /// Runs on the link's thread for every message handed to the bridge, before it is
    /// checked against the bridge's link: a write that has begun.
    var onHanded: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { handingHook } }
        set { lock.withLock { handingHook = newValue } }
    }
    private var started: Set<ObjectIdentifier> = []
    private var stopCount = 0
    private var claimList: [[Int]] = []
    private var heldList: [[Int]] = []
    private var claimsHeld = false
    private var resets = 0
    private var holds = false
    private var gone: (@Sendable () -> Void)?
    private var beforeReconnectHook: (() -> Void)?

    init(path: String, link: any TerminalStreamLink, helperConnected: Bool = true) {
        helperSocketPath = path
        helperThere = helperConnected
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
        attach(link)
        if let old { stopOnce(old) }
    }
    func stop() {
        let current = lock.withLock { () -> (any TerminalStreamLink)? in
            stopCount += 1
            return stopCount == 1 ? linkList.last : nil
        }
        if let current { stopOnce(current) }
    }

    private func stopOnce(_ link: any TerminalStreamLink) {
        let first = lock.withLock { stoppedLinks.insert(ObjectIdentifier(link)).inserted }
        if first { link.stop() }
    }

    /// The helper went away by itself: as the real bridge, on the helper's thread, the
    /// current link is stopped, then the owner is told.
    func helperWentAway() {
        let current = lock.withLock { linkList.last }
        if let current { stopOnce(current) }
        if lock.withLock({ stopCount == 0 }) { onHelperGone?() }
    }

    /// The helper connects: the link the bridge holds now starts.
    func helperConnects() {
        lock.withLock { helperThere = true }
        startIfReady()
    }

    private func attach(_ link: any TerminalStreamLink) {
        lock.withLock { linkList.append(link) }
        startIfReady()
    }

    /// Starts the current link if the helper is there and it has not been started.
    private func startIfReady() {
        let current = lock.withLock { () -> (any TerminalStreamLink)? in
            guard helperThere, stopCount == 0, let link = linkList.last,
                  !started.contains(ObjectIdentifier(link)) else { return nil }
            started.insert(ObjectIdentifier(link))
            return link
        }
        guard let link = current else { return }
        // As the real bridge: its own handlers, then the start.
        let id = ObjectIdentifier(link)
        link.onMessage = { [weak self] message in
            guard let self else { return }
            self.onHanded?(message)
            self.lock.withLock {
                if let current = self.linkList.last, ObjectIdentifier(current) == id {
                    self.messageList.append(message)
                } else {
                    self.droppedList.append(message)
                }
            }
        }
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
        observers[id] = nil
    }
    /// Whether a surface takes every grid imposed at once (most tests), or keeps
    /// `sizes` until the test reports a grid (`report(grid:for:)`).
    var followsImpose = true
    var sizes: [String: TerminalSize] = [:]
    private var observers: [String: @MainActor (TerminalSize) -> Void] = [:]

    func impose(grid: TerminalSize?, on id: String) {
        imposed.append((grid, id))
        if followsImpose, let grid { sizes[id] = grid }
    }
    func view(id: String) -> NSView? { views[id] }
    func size(id: String) -> TerminalSize? { sizes[id] }
    func observeViewerGrid(id: String, _ handler: @escaping @MainActor (TerminalSize) -> Void) {
        observers[id] = handler
    }

    /// The surface `id` took `grid`, as the view's `synchronizeMetrics` reports it.
    func report(grid: TerminalSize, for id: String) {
        sizes[id] = grid
        observers[id]?(grid)
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []
    private let added = DispatchSemaphore(value: 0)
    var all: [Int] { lock.withLock { list } }
    func add(_ value: Int) {
        lock.withLock { list.append(value) }
        added.signal()
    }
    /// Waits (five seconds at most) for the next value added. Whether one was.
    func waitForNext() -> Bool { added.wait(timeout: .now() + 5) == .success }
}

/// What the store holds and what the factories made, reached by the pane's closures.
@MainActor
private final class Made {
    var connections: [RemoteConnection] = []
    var links: [FakeLink] = []
    var bridges: [FakeBridge] = []
    var failBridge = false
    /// Whether the helper of each bridge made is there from the start.
    var helperConnectsAtOnce = true
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
                let bridge = FakeBridge(path: "/tmp/wty-\(made.bridges.count).sock", link: link,
                                        helperConnected: made.helperConnectsAtOnce)
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

    /// The current link delivers its snapshot, on a thread of its own (the link's
    /// callback may be held until the main actor releases it), and the hops run.
    func snapshot() {
        let call = deliver([.snapshot([0x1B, 0x63])])
        #expect(main.run(until: { call.hasFinished }))
    }

    /// `link` delivers `messages` one after the other on a thread of its own, as the
    /// link's thread would. Nothing is run on the main actor here.
    func deliver(_ messages: [StreamMessage], on link: FakeLink? = nil) -> BackgroundCall {
        let link = link ?? self.link
        return BackgroundCall { for message in messages { link.deliver(message) } }
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
        #expect(isInert(rig.bridge.links[1]))
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

    /// The first link's timeout fires before the helper has connected to the bridge, so
    /// the bridge has started no link: the attempt still counts as lost, the unstarted
    /// link is retired, and the next one starts when the helper connects.
    @Test func aTimeoutBeforeTheHelperConnectedCountsAsLostAndTheNextLinkStartsWhenItDoes() {
        let rig = Rig()
        rig.made.helperConnectsAtOnce = false
        let pane = rig.shown()
        let first = rig.link
        #expect(first.starts == 0)
        #expect(rig.timers.watchdogs.map(\.due) == [rig.timers.now + 15])
        rig.timers.fireNext()
        #expect(pane.state == .reconnecting)
        #expect(first.starts == 0)
        #expect(first.stops == 1)
        #expect(rig.bridge.links.count == 3)
        #expect(isInert(rig.bridge.links[1]))
        #expect(rig.links.count == 2)
        let second = rig.link
        #expect(second.starts == 0)
        #expect(rig.timers.watchdogs.count == 1)
        #expect(rig.host.created.count == 1)

        rig.bridge.helperConnects()
        #expect(first.starts == 0)
        #expect(second.starts == 1)
        rig.snapshot()
        #expect(pane.state == .live)
        #expect(rig.timers.watchdogs.isEmpty)
    }

    /// A helper that never connects: every attempt times out unstarted, until the 2
    /// minutes are over and the pane waits for the button. Shown as a lost connection,
    /// though the fault is on this Mac.
    @Test func aHelperThatNeverConnectsEndsInWaiting() {
        let rig = Rig()
        rig.made.helperConnectsAtOnce = false
        let pane = rig.shown()
        let start = rig.timers.now
        for _ in 0..<100 where !rig.timers.live.isEmpty { rig.timers.fireNext() }
        #expect(pane.state == .waiting)
        #expect(rig.timers.live.isEmpty)
        #expect(rig.links.count > 2)
        #expect(rig.links.allSatisfy { $0.starts == 0 })
        // The 2 minutes run from the first timeout, and the last attempt's own timeout
        // ends them.
        #expect(rig.timers.now - start <= RemoteReconnectPolicy.automaticPhase + 2 * RemotePane.attemptTimeout)
        #expect(rig.host.created.count == 1)
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
        #expect(isInert(rig.bridge.links.last!))
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

    // MARK: Fix round 2: a snapshot waits for the surface's grid

    private static let ownGrid = TerminalSize(cols: 124, rows: 40)
    private static let inForce = TerminalSize(cols: 100, rows: 30)
    private static let snapshotBytes: [UInt8] = [0x1B, 0x63, 0x53]
    private static let dataBytes: [UInt8] = [0x44]

    /// A shown pane whose surface has its own grid and takes an imposed grid only when
    /// the test reports it; the link has sent the `resize` of the grid in force, and the
    /// view was given it.
    private func paneAtAnotherGrid() throws -> (Rig, RemotePane, String) {
        let rig = Rig()
        rig.host.followsImpose = false
        let pane = rig.shown()
        let id = try #require(pane.surfaceId)
        rig.host.sizes[id] = Self.ownGrid
        rig.link.deliver(.resize(cols: Self.inForce.cols, rows: Self.inForce.rows, own: false))
        rig.main.drain()
        #expect(rig.host.imposed.last?.0 == Self.inForce)
        return (rig, pane, id)
    }

    /// Starts the snapshot and a data message behind it on the link's thread, and runs
    /// the main actor until the pane has decided to hold it.
    private func heldSnapshot(_ rig: Rig, on link: FakeLink? = nil) -> BackgroundCall {
        let made = rig.timers.secondTimersMade
        let call = rig.deliver([.snapshot(Self.snapshotBytes), .data(Self.dataBytes)], on: link)
        #expect(rig.main.run(until: { rig.timers.secondTimersMade > made }))
        return call
    }

    /// What the bridge was handed that it writes to the helper: every message but the
    /// `resize`, which goes to `onResize`.
    private func payloads(_ bridge: FakeBridge) -> [StreamMessage] {
        bridge.messages.filter { if case .resize = $0 { false } else { true } }
    }

    private func snapshots(_ bridge: FakeBridge) -> Int {
        bridge.messages.filter { if case .snapshot = $0 { true } else { false } }.count
    }

    /// The retiring link of an attempt timeout: an inert one, observed for the answers.
    private func isInert(_ link: any TerminalStreamLink) -> Bool {
        (link as? ObservedLink)?.inner is InertLink
    }

    private func queries(_ bridge: FakeBridge) -> Int {
        bridge.messages.filter { $0 == .data(SizeAnswerScanner.query) }.count
    }

    /// The stream's own payloads the bridge was handed, without the size queries.
    private func streamPayloads(_ bridge: FakeBridge) -> [StreamMessage] {
        payloads(bridge).filter { $0 != .data(SizeAnswerScanner.query) }
    }

    private static func answer(_ size: TerminalSize) -> [UInt8] {
        Array("\u{1B}[8;\(size.rows);\(size.cols)t".utf8)
    }

    /// The surface's input reaching the bridge's current link, as the helper thread hands
    /// it over.
    private func surfaceTypes(_ rig: Rig, _ bytes: [UInt8]) {
        rig.bridge.links.last!.send(bytes)
    }

    /// Every byte any link of the rig sent to the other Mac.
    private func serverInput(_ rig: Rig) -> [UInt8] {
        rig.links.flatMap(\.sentBytes)
    }

    @Test func aHeldSnapshotPassesWhenTheTerminalAnswersTheGridAfterTheSurfaceReportedIt() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let call = heldSnapshot(rig)
        // Held: neither the snapshot nor the data behind it reached the bridge, and the
        // terminal is not asked before the surface reported the grid.
        #expect(payloads(rig.bridge).isEmpty)
        #expect(!call.hasFinished)
        #expect(pane.state == .connecting)
        rig.host.report(grid: TerminalSize(cols: 110, rows: 35), for: id)
        rig.main.drain()
        #expect(payloads(rig.bridge).isEmpty)

        rig.host.report(grid: Self.inForce, for: id)
        // One query, written by the held callback, as output to the surface.
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        #expect(!call.hasFinished)
        #expect(streamPayloads(rig.bridge).isEmpty)
        // The answer, between keys the user typed meanwhile, in one read.
        surfaceTypes(rig, Array("ab".utf8) + Self.answer(Self.inForce) + Array("c".utf8))
        #expect(rig.main.run(until: { call.hasFinished }))
        // In the link's order, the snapshot first.
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(queries(rig.bridge) == 1)
        #expect(serverInput(rig) == Array("abc".utf8))
        #expect(pane.state == .live)
        #expect(rig.timers.holdLimits.isEmpty)
        #expect(rig.timers.watchdogs.isEmpty)
    }

    @Test func anAnswerNamingAnotherGridAsksAgainAfterTenMilliseconds() throws {
        let (rig, _, id) = try paneAtAnotherGrid()
        let call = heldSnapshot(rig)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        // The terminal has not taken the grid yet.
        surfaceTypes(rig, Self.answer(Self.ownGrid))
        rig.main.drain()
        #expect(!call.hasFinished)
        #expect(queries(rig.bridge) == 1)
        let retry = try #require(rig.timers.live.first { $0.delay == RemotePane.sizeQueryRetry })
        #expect(retry.due == rig.timers.now + 0.01)
        rig.timers.fire(retry)
        #expect(rig.main.run(until: { queries(rig.bridge) == 2 }))
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(rig.main.run(until: { call.hasFinished }))
        #expect(queries(rig.bridge) == 2)
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(serverInput(rig).isEmpty)
    }

    @Test func theTerminalIsAskedAtOnceWhenTheSurfaceHasTheGridAlready() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        rig.host.sizes[id] = Self.inForce
        let call = rig.deliver([.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(rig.main.run(until: { call.hasFinished }))
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(pane.state == .live)
        #expect(serverInput(rig).isEmpty)
    }

    @Test func aSnapshotIsPassedAtOnceWhenTheViewShowsThePanesOwnSize() throws {
        let rig = Rig()
        rig.host.followsImpose = false
        let pane = rig.shown()
        rig.host.sizes[pane.surfaceId!] = Self.ownGrid
        let created = rig.timers.all.count
        rig.snapshot()
        #expect(snapshots(rig.bridge) == 1)
        #expect(queries(rig.bridge) == 0)
        #expect(rig.timers.all.count == created)
    }

    /// The bound passes the snapshot with a query outstanding: its late answer is still
    /// taken out, and the next bytes that look the same pass.
    @Test func theBoundPassesItAndTheOutstandingAnswerIsStillTakenOut() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let call = heldSnapshot(rig)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        let limit = rig.timers.holdLimits[0]
        #expect(limit.due == rig.timers.now + 1)
        rig.timers.fire(limit)
        #expect(rig.main.run(until: { call.hasFinished }))
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(pane.state == .live)
        surfaceTypes(rig, Self.answer(Self.ownGrid))
        #expect(serverInput(rig).isEmpty)
        surfaceTypes(rig, Self.answer(Self.ownGrid))
        #expect(serverInput(rig) == Self.answer(Self.ownGrid))
        rig.main.drain()
        #expect(queries(rig.bridge) == 1)
    }

    /// The main actor stops the link while its callback waits for the main actor: the
    /// stop releases it first, so it returns, and the snapshot is never written. The
    /// query it had written still has its answer taken out.
    @Test func closeReleasesAHeldSnapshotAndDropsIt() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let link = rig.link
        let call = heldSnapshot(rig)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        let limit = rig.timers.holdLimits[0]
        let observed = rig.bridge.links.last!
        rig.panes.close(rig.ref)
        #expect(!link.stopTimedOut)
        #expect(call.wait())
        rig.main.drain()
        #expect(snapshots(rig.bridge) == 0)
        #expect(limit.cancelled)
        // A late fire, a late report, the late answer: nothing, and nothing to the server.
        limit.work()
        rig.host.report(grid: Self.inForce, for: id)
        observed.send(Self.answer(Self.inForce))
        rig.main.drain()
        #expect(snapshots(rig.bridge) == 0)
        #expect(pane.state == .connecting)
        #expect(serverInput(rig).isEmpty)
        observed.send(Self.answer(Self.inForce))
        #expect(serverInput(rig) == Self.answer(Self.inForce))
    }

    @Test func theButtonReplacingTheLinkReleasesItsHeldSnapshotAndTheAnswerStillGoesOut() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        rig.lose()
        let out = rig.link
        out.deliver(.resize(cols: Self.inForce.cols, rows: Self.inForce.rows, own: false))
        rig.main.drain()
        let call = heldSnapshot(rig, on: out)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        let limit = rig.timers.holdLimits[0]
        pane.reconnectPressed()
        #expect(!out.stopTimedOut)
        #expect(call.wait())
        rig.main.drain()
        #expect(snapshots(rig.bridge) == 0)
        #expect(limit.cancelled)
        #expect(rig.bridge.links.count == 3)
        #expect(pane.state == .reconnecting)
        // The answer comes back through the new link: taken out there.
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(serverInput(rig).isEmpty)
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(rig.link.sentBytes == Self.answer(Self.inForce))
    }

    @Test func theAttemptTimeoutReleasesAHeldSnapshotAndItsAnswerIsTakenOut() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let first = rig.link
        let call = heldSnapshot(rig)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        let watchdog = try #require(rig.timers.watchdogs.first)
        let limit = rig.timers.holdLimits[0]
        let before = rig.timers.all.count
        rig.timers.fire(watchdog)
        #expect(!first.stopTimedOut)
        #expect(call.wait())
        rig.main.drain()
        #expect(snapshots(rig.bridge) == 0)
        #expect(limit.cancelled)
        // The query is still out: given up on a second from now unless answered first.
        let expiry = try #require(rig.timers.made(since: before, delay: RemotePane.sizeQueryExpiry).first)
        #expect(pane.state == .reconnecting)
        #expect(isInert(rig.bridge.links[1]))
        // Through the inert link (the retry's link is not there yet in this order) or
        // the retry's: either way taken out.
        rig.bridge.links[1].send(Self.answer(Self.inForce))
        #expect(serverInput(rig).isEmpty)
        rig.main.drain()
        #expect(expiry.cancelled)
    }

    /// A query asked and never written (another token, a stopped link) is withdrawn: no
    /// answer is waited for, and nothing is taken out for it.
    @Test func aQueryNeverWrittenIsWithdrawn() {
        let inner = FakeLink(connection: RemoteConnection(id: UUID(), name: "n", host: "h", port: 1, token: "t"),
                             session: "s")
        let filter = SizeAnswerFilter { _ in }
        let tokens = TokenBox()
        let link = ObservedLink(inner, holdsSnapshots: true, answers: filter) { event in
            if case .snapshotWaiting(let token) = event { tokens.add(token) }
        }
        link.onMessage = { _ in }
        let call = BackgroundCall { inner.deliver(.snapshot([0x41])) }
        // Told after the hold is in place.
        #expect(tokens.waitForNext())
        #expect(link.isHoldingSnapshot)
        #expect(!link.askSize(token: tokens.all[0] + 1, query: filter.queried()))
        #expect(filter.outstanding == 0)
        link.stop()
        #expect(call.wait())
        #expect(!link.askSize(token: tokens.all[0], query: filter.queried()))
        #expect(filter.outstanding == 0)
        link.send(Self.answer(Self.inForce))
        #expect(inner.sentBytes == Self.answer(Self.inForce))
    }

    /// The link's own stop, from the thread its held callback waits for, releases the
    /// snapshot first: the inner link's stop (which waits for that callback) returns, and
    /// the snapshot is not passed on.
    @Test func stoppingTheLinkReleasesAHeldSnapshotWithoutPassingIt() {
        let inner = FakeLink(connection: RemoteConnection(id: UUID(), name: "n", host: "h", port: 1, token: "t"),
                             session: "s")
        let held = TokenBox()
        let link = ObservedLink(inner, holdsSnapshots: true) { event in
            if case .snapshotWaiting(let token) = event { held.add(token) }
        }
        let passed = TokenBox()
        link.onMessage = { _ in passed.add(1) }
        let call = BackgroundCall { inner.deliver(.snapshot([0x41])) }
        #expect(held.waitForNext())
        #expect(link.isHoldingSnapshot)
        link.stop()
        #expect(!inner.stopTimedOut)
        #expect(call.wait())
        #expect(passed.all.isEmpty)
        #expect(!link.isHoldingSnapshot)
    }

    @Test func aReleaseForAnotherTokenOrAfterAStopDoesNothing() {
        let inner = FakeLink(connection: RemoteConnection(id: UUID(), name: "n", host: "h", port: 1, token: "t"),
                             session: "s")
        let tokens = TokenBox()
        let link = ObservedLink(inner, holdsSnapshots: true) { event in
            if case .snapshotWaiting(let token) = event { tokens.add(token) }
        }
        let passed = TokenBox()
        link.onMessage = { _ in passed.add(1) }
        let call = BackgroundCall { inner.deliver(.snapshot([0x41])) }
        #expect(tokens.waitForNext())
        #expect(link.isHoldingSnapshot)
        // A release is decided under the link's lock and returns at once: one for
        // another token has left the hold in place.
        link.releaseSnapshot(token: tokens.all[0] + 1, pass: true)
        #expect(link.isHoldingSnapshot)
        #expect(passed.all.isEmpty)
        link.releaseSnapshot(token: tokens.all[0], pass: true)
        #expect(call.wait())
        #expect(passed.all == [1])
        // After a stop, a snapshot is dropped without being held.
        link.stop()
        let late = BackgroundCall { inner.deliver(.snapshot([0x42])) }
        #expect(late.wait())
        #expect(passed.all == [1])
        #expect(tokens.all.count == 1)
    }

    // MARK: Hold fix: lost queries, held bytes, late answers

    private static let other = TerminalSize(cols: 90, rows: 26)

    /// The pane's grid in force once more, on the link it has now.
    private func resize(_ rig: Rig, to size: TerminalSize, on link: FakeLink? = nil) {
        (link ?? rig.link).deliver(.resize(cols: size.cols, rows: size.rows, own: false))
        rig.main.drain()
    }

    /// The pane at another grid, made live by a first snapshot the terminal answered for.
    private func livePaneAtAnotherGrid() throws -> (Rig, RemotePane, String) {
        let (rig, pane, id) = try paneAtAnotherGrid()
        rig.host.sizes[id] = Self.inForce
        let first = rig.deliver([.snapshot(Self.snapshotBytes)])
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(rig.main.run(until: { first.hasFinished }))
        #expect(pane.state == .live)
        return (rig, pane, id)
    }

    /// A lone ESC typed while the query is out is held (it could start the answer), and
    /// passes before the keys after the answer, which is taken out.
    @Test func aLoneEscapeWhileTheQueryIsOutPassesInOrderAroundTheAnswer() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let call = heldSnapshot(rig)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        surfaceTypes(rig, [0x1B])
        #expect(serverInput(rig).isEmpty)
        surfaceTypes(rig, Self.answer(Self.inForce) + Array("k".utf8))
        #expect(rig.main.run(until: { call.hasFinished }))
        #expect(serverInput(rig) == [0x1B] + Array("k".utf8))
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(pane.state == .live)
        // Answered: nothing to give up on.
        #expect(rig.timers.live.isEmpty)
    }

    /// The link is stopped with its query still queued (never written) and an ESC held
    /// for that query: the ESC is not lost, it reaches the link the bridge has then, on
    /// the next read, before that read's bytes.
    @Test func aStopWithTheQueryQueuedKeepsAHeldEscapeForTheNextRead() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        rig.lose()
        let out = rig.link
        resize(rig, to: Self.inForce, on: out)
        // The surface has the grid: the query is asked in the turn the hold is told of.
        rig.host.sizes[id] = Self.inForce
        // The link's thread stays in that hop until the link is stopped, so the query is
        // still on its queue then.
        let gate = DispatchSemaphore(value: 0)
        rig.main.holdNextHop(until: gate)
        out.beforeStopWaits = { gate.signal() }
        let call = heldSnapshot(rig, on: out)
        surfaceTypes(rig, [0x1B])
        #expect(serverInput(rig).isEmpty)
        pane.reconnectPressed()
        #expect(!out.stopTimedOut)
        #expect(call.wait())
        rig.main.drain()
        #expect(queries(rig.bridge) == 0)
        #expect(snapshots(rig.bridge) == 0)
        #expect(serverInput(rig).isEmpty)
        surfaceTypes(rig, Array("x".utf8))
        #expect(rig.link.sentBytes == [0x1B] + Array("x".utf8))
    }

    /// The button replaces the link after its held callback took the query off its queue
    /// and before the bridge wrote it: the bridge skips the write, so no answer comes.
    /// The query is given up on a second later; until then the next hold cannot ask (one
    /// query out per pane) and an ESC is held; after it the next hold asks its own query,
    /// the ESC passes, and a look-alike answer the user types later passes too.
    @Test func aQueryLostBetweenTakenAndWrittenExpiresAfterASecond() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        rig.lose()
        let out = rig.link
        let bridge = rig.bridge
        resize(rig, to: Self.inForce, on: out)
        let taken = DispatchSemaphore(value: 0)
        let swapped = DispatchSemaphore(value: 0)
        bridge.onHanded = { message in
            guard message == .data(SizeAnswerScanner.query) else { return }
            taken.signal()
            _ = swapped.wait(timeout: .now() + 5)
        }
        // The old link's stop comes after the swap.
        out.beforeStopWaits = { swapped.signal() }
        let call = heldSnapshot(rig, on: out)
        rig.host.report(grid: Self.inForce, for: id)
        rig.main.drain()
        #expect(taken.wait(timeout: .now() + 5) == .success)
        let limit = rig.timers.holdLimits[0]
        let before = rig.timers.all.count
        pane.reconnectPressed()
        #expect(!out.stopTimedOut)
        #expect(call.wait())
        rig.main.drain()
        bridge.onHanded = nil
        // Dropped: the query, and what the fake link still delivered behind the snapshot.
        #expect(bridge.dropped.first == .data(SizeAnswerScanner.query))
        #expect(queries(bridge) == 0)
        #expect(limit.cancelled)
        let expiry = try #require(rig.timers.made(since: before, delay: RemotePane.sizeQueryExpiry).first)
        #expect(expiry.due == rig.timers.now + 1)

        // The next link's snapshot is held, and cannot ask while the lost query is out.
        resize(rig, to: Self.inForce)
        let second = heldSnapshot(rig)
        rig.main.drain()
        #expect(queries(bridge) == 0)
        surfaceTypes(rig, [0x1B])
        #expect(serverInput(rig).isEmpty)

        rig.timers.fire(expiry)
        #expect(rig.main.run(until: { queries(bridge) == 1 }))
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(rig.main.run(until: { second.hasFinished }))
        #expect(pane.state == .live)
        #expect(serverInput(rig) == [0x1B])
        let typed = Array("\u{1B}[8;24;80t".utf8)
        surfaceTypes(rig, typed)
        #expect(serverInput(rig) == [0x1B] + typed)
    }

    /// The end of a link that holds a snapshot waits behind it, as on the link's one
    /// queue: the bound passes the snapshot, the end follows, and the query that was
    /// never answered is given up on a second after the hold, so an ESC held for it and a
    /// look-alike answer typed then pass.
    @Test func aLinkThatEndsWhileHoldingEndsAfterTheHoldAndItsQueryExpires() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let first = rig.link
        let made = rig.timers.secondTimersMade
        let snapshotBytes = Self.snapshotBytes
        let dataBytes = Self.dataBytes
        let call = BackgroundCall {
            first.deliver(.snapshot(snapshotBytes))
            first.deliver(.data(dataBytes))
            first.end(.connectionLost)
        }
        #expect(rig.main.run(until: { rig.timers.secondTimersMade > made }))
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        #expect(!call.hasFinished)
        #expect(rig.links.count == 1)
        let before = rig.timers.all.count
        rig.timers.fire(rig.timers.holdLimits[0])
        #expect(rig.main.run(until: { call.hasFinished }))
        rig.main.drain()
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(pane.state == .reconnecting)
        #expect(rig.links.count == 2)
        let expiry = try #require(rig.timers.made(since: before, delay: RemotePane.sizeQueryExpiry).first)
        surfaceTypes(rig, [0x1B])
        #expect(serverInput(rig).isEmpty)
        rig.timers.fire(expiry)
        rig.main.drain()
        let typed = Array("\u{1B}[8;24;80t".utf8)
        surfaceTypes(rig, typed)
        #expect(serverInput(rig) == [0x1B] + typed)
    }

    /// The helper goes away while a snapshot is held with its query out: the bridge stops
    /// the link first (the hold returns, nothing written), the pane ends, and no timer of
    /// it is left, the query's expiry included.
    @Test func theHelperGoingAwayWhileHoldingLeavesNothingRunning() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        let call = heldSnapshot(rig)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        rig.bridge.helperWentAway()
        #expect(!rig.link.stopTimedOut)
        #expect(call.wait())
        #expect(snapshots(rig.bridge) == 0)
        rig.main.drain()
        guard case .refused = pane.state else {
            Issue.record("state is \(pane.state)")
            return
        }
        #expect(rig.bridge.stops == 1)
        #expect(rig.host.destroyed == [id])
        #expect(rig.timers.live.isEmpty)
    }

    /// A `resize` during live output is passed on as it comes, with nothing held behind
    /// it: the link's thread delivers it and the data around it without a main turn.
    @Test func aResizeDuringLiveOutputHoldsNothing() throws {
        let (rig, _, _) = try livePaneAtAnotherGrid()
        let made = rig.timers.all.count
        let call = rig.deliver([.data([0x31]), .resize(cols: Self.other.cols, rows: Self.other.rows, own: false),
                                .data([0x32])])
        #expect(call.wait())
        #expect(streamPayloads(rig.bridge) == [.snapshot(Self.snapshotBytes), .data([0x31]), .data([0x32])])
        rig.main.drain()
        #expect(rig.host.imposed.last?.0 == Self.other)
        #expect(rig.timers.all.count == made)
        #expect(queries(rig.bridge) == 1)
    }

    /// A resync snapshot on a live link, at a grid the surface has yet to take, is held
    /// and released like the first.
    @Test func aResyncSnapshotOnALiveLinkIsHeldAndReleasedLikeTheFirst() throws {
        let (rig, pane, id) = try livePaneAtAnotherGrid()
        resize(rig, to: Self.other)
        let call = heldSnapshot(rig)
        #expect(!call.hasFinished)
        #expect(snapshots(rig.bridge) == 1)
        #expect(queries(rig.bridge) == 1)
        rig.host.report(grid: Self.other, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 2 }))
        surfaceTypes(rig, Self.answer(Self.other))
        #expect(rig.main.run(until: { call.hasFinished }))
        #expect(snapshots(rig.bridge) == 2)
        #expect(Array(streamPayloads(rig.bridge).suffix(2)) == [.snapshot(Self.snapshotBytes), .data(Self.dataBytes)])
        #expect(serverInput(rig).isEmpty)
        #expect(pane.state == .live)
        #expect(rig.timers.live.isEmpty)
    }

    /// The late answer to a replaced link's query names the grid the next hold waits for,
    /// but it was asked before that hold began: it releases nothing. It frees the pane's
    /// one query, so the hold asks its own, and passes on that answer.
    @Test func aLateAnswerToAReplacedLinksQueryReleasesNothing() throws {
        let (rig, pane, id) = try paneAtAnotherGrid()
        rig.lose()
        let out = rig.link
        resize(rig, to: Self.inForce, on: out)
        let call = heldSnapshot(rig, on: out)
        rig.host.report(grid: Self.inForce, for: id)
        #expect(rig.main.run(until: { queries(rig.bridge) == 1 }))
        let before = rig.timers.all.count
        pane.reconnectPressed()
        #expect(call.wait())
        rig.main.drain()
        let expiry = try #require(rig.timers.made(since: before, delay: RemotePane.sizeQueryExpiry).first)

        resize(rig, to: Self.inForce)
        let second = heldSnapshot(rig)
        rig.main.drain()
        #expect(queries(rig.bridge) == 1)
        surfaceTypes(rig, Self.answer(Self.inForce))
        rig.main.drain()
        #expect(expiry.cancelled)
        #expect(!second.hasFinished)
        #expect(snapshots(rig.bridge) == 0)
        #expect(rig.main.run(until: { queries(rig.bridge) == 2 }))
        surfaceTypes(rig, Self.answer(Self.inForce))
        #expect(rig.main.run(until: { second.hasFinished }))
        #expect(snapshots(rig.bridge) == 1)
        #expect(serverInput(rig).isEmpty)
        #expect(pane.state == .live)
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
            case .snapshotWaiting: events.add("held")
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
