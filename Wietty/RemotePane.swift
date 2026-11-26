import AppKit
import Foundation
import Observation
import OSLog
import WiettyCore
import WiettyShared

/// What a remote pane needs of the surface host. `GhosttySurfaceHost` is the one in
/// the app; a test hands in its own.
@MainActor
protocol ViewerSurfaceHosting: AnyObject {
    func createViewerSurface(id: String, command: String, grid: OwnPaneGrid?) throws
    func destroySurface(id: String)
    func impose(grid: TerminalSize?, on id: String)
    func view(id: String) -> NSView?
    /// The surface's grid now, as libghostty has it.
    func size(id: String) -> TerminalSize?
    /// Every grid the surface reports from now on, until it is destroyed.
    func observeViewerGrid(id: String, _ handler: @escaping @MainActor (TerminalSize) -> Void)
}

extension GhosttySurfaceHost: ViewerSurfaceHosting {}

/// What a remote pane needs of its bridge. `TerminalBridge` is the one in the app; a
/// test hands in its own. See `TerminalBridge` for what each member promises.
protocol ViewerBridging: AnyObject, Sendable {
    var helperSocketPath: String { get }
    var holdsClaimsUntilReset: Bool { get set }
    var onHelperGone: (@Sendable () -> Void)? { get set }
    @discardableResult func claim(cols: Int, rows: Int) -> Bool
    func resetClaims()
    func reconnect(with newLink: any TerminalStreamLink)
    func stop()
}

extension TerminalBridge: ViewerBridging {}

/// A link as the bridge is handed it, telling its owner what the bridge cannot: that it
/// delivered its first snapshot, each `resize`, and its end, each tagged with the link's
/// generation so the owner can drop what a replaced link still reports.
///
/// The bridge sets `onMessage` and `onEnded` when it starts the link; this wraps them,
/// so the bridge's handler runs first (the snapshot is written to the helper, the end
/// marks the bridge's held claims) and the owner is told after, on the link's thread.
/// `TerminalBridge` is not changed for it.
///
/// ## Holding a snapshot
///
/// With `holdsSnapshots`, a `snapshot` is not handed to the bridge (which writes it to
/// the helper at once) until the owner releases it. The `resize` before it on this link
/// reaches the surface by another route (the main actor's grid, the view's size, then
/// `ghostty_surface_set_size` some turns later), and a snapshot parsed at the surface's
/// old grid and resized after is not the server's screen (step 5 measurement, R1 at
/// another grid and RECONNECT). The link's callback blocks here, as it blocks in the
/// bridge's write: that is the backpressure, and since a link delivers one message at a
/// time, nothing behind the snapshot overtakes it. The owner is told through `observe`
/// (`.snapshotWaiting`) and answers with `releaseSnapshot(token:pass:)`.
///
/// Only the snapshot is held. A `resize` during live output is passed on as it comes,
/// with nothing held behind it: an owner dragging its window would otherwise stall its
/// own output on every step.
///
/// `stop()` releases a held snapshot first, and drops it, before it stops the inner
/// link (whose `stop()` waits for a running callback, this one included): so a stop on
/// the main actor, where the release would have come from, never waits for itself. The
/// bridge stops the link it replaces and the link it has when it stops, so a
/// replacement and a close both release. A snapshot released after a stop is dropped,
/// never written.
final class ObservedLink: TerminalStreamLink, @unchecked Sendable {
    enum Event: Sendable {
        case snapshot
        case resize(TerminalSize, own: Bool)
        case ended(TerminalEndReason)
        /// A snapshot is held until `releaseSnapshot(token:pass:)` with this token.
        case snapshotWaiting(token: Int)
    }

    let inner: any TerminalStreamLink
    private let observe: @Sendable (Event) -> Void
    private let holdsSnapshots: Bool
    private let lock = NSLock()
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var snapshotSeen = false
    // The hold, under `lock`.
    private var stopped = false
    private var holdToken = 0
    private var held: (token: Int, wake: DispatchSemaphore)?
    private var heldPasses = false

    /// - Parameter holdsSnapshots: hold every snapshot until the owner releases it.
    /// - Parameter observe: called on the link's thread, after the bridge's handler
    ///   (before it, for `.snapshotWaiting`), and must return at once (hop, never wait
    ///   on the main thread).
    init(_ inner: any TerminalStreamLink, holdsSnapshots: Bool = false,
         observe: @escaping @Sendable (Event) -> Void) {
        self.inner = inner
        self.holdsSnapshots = holdsSnapshots
        self.observe = observe
    }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set {
            lock.withLock { messageHandler = newValue }
            inner.onMessage = newValue.map { handler -> @Sendable (StreamMessage) -> Void in
                { [weak self] message in
                    if case .snapshot = message, let self, self.holdsSnapshots {
                        guard self.hold() else { return }
                    }
                    handler(message)
                    self?.observed(message)
                }
            }
        }
    }

    /// Whether a snapshot is held now. For tests.
    var isHoldingSnapshot: Bool { lock.withLock { held != nil } }

    /// Releases the snapshot held under `token`: passed on to the bridge when `pass`,
    /// else dropped. Nothing for another token, or when none is held. Never blocks.
    func releaseSnapshot(token: Int, pass: Bool) {
        let wake = lock.withLock { () -> DispatchSemaphore? in
            guard let held, held.token == token else { return nil }
            self.held = nil
            heldPasses = pass
            return held.wake
        }
        wake?.signal()
    }

    /// On the link's thread: blocks until the owner releases the snapshot or the link is
    /// stopped. Whether to pass it on.
    private func hold() -> Bool {
        let (token, wake) = lock.withLock { () -> (Int, DispatchSemaphore?) in
            guard !stopped else { return (0, nil) }
            holdToken += 1
            let wake = DispatchSemaphore(value: 0)
            held = (holdToken, wake)
            heldPasses = false
            return (holdToken, wake)
        }
        guard let wake else { return false }
        observe(.snapshotWaiting(token: token))
        wake.wait()
        // A stop after the release still drops it.
        return lock.withLock { heldPasses && !stopped }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set {
            lock.withLock { endHandler = newValue }
            inner.onEnded = newValue.map { handler -> @Sendable (TerminalEndReason) -> Void in
                { [observe] reason in
                    handler(reason)
                    observe(.ended(reason))
                }
            }
        }
    }

    func start() { inner.start() }

    /// Releases and drops a held snapshot, then stops the inner link (which waits for a
    /// running callback; the held one returns at once now).
    func stop() {
        let wake = lock.withLock { () -> DispatchSemaphore? in
            stopped = true
            heldPasses = false
            defer { held = nil }
            return held?.wake
        }
        wake?.signal()
        inner.stop()
    }

    func send(_ bytes: [UInt8]) { inner.send(bytes) }
    func claim(cols: Int, rows: Int) { inner.claim(cols: cols, rows: rows) }

    private func observed(_ message: StreamMessage) {
        switch message {
        case .snapshot:
            let first = lock.withLock { () -> Bool in
                defer { snapshotSeen = true }
                return !snapshotSeen
            }
            if first { observe(.snapshot) }
        case let .resize(cols, rows, own):
            observe(.resize(TerminalSize(cols: cols, rows: rows), own: own))
        case .data, .repaint, .hello, .error, .ended:
            break
        }
    }
}

/// A link that never starts anything, never delivers and never ends: what the bridge is
/// handed to retire a link that timed out when no new link follows at once, since
/// `TerminalBridge` stops a link only by replacing it or by stopping altogether.
final class InertLink: TerminalStreamLink, @unchecked Sendable {
    private let lock = NSLock()
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }
    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }
    func start() {}
    func stop() {}
    func send(_ bytes: [UInt8]) {}
    func claim(cols: Int, rows: Int) {}
}

/// The pane of one terminal on another Mac, while it is shown: its viewer surface, the
/// `TerminalBridge` the surface's helper connects to, the pane's grid, the current link,
/// and the reconnect policy with its one timer.
///
/// **Lifetime.** Made by `RemotePanes.open` when the pane is shown and closed by
/// `RemotePanes.close` when it is hidden; showing it again makes a new one, with a new
/// surface and a new attach. Nothing is kept across a hide: a viewer that became the
/// grid's owner would otherwise claim again when its surface came back on display.
///
/// **The surface.** Created no sooner than the main turn after `open`, and after any
/// destroy of a viewer surface (`ViewerSurfaceGate`): R8 of the step 5 measurement
/// found a surface created in the turn of a destroy could receive the destroyed one's
/// late messages. The host drains libghostty's mailbox on destroy too; this is the
/// second line. Its id is `rv:<connection>:<session>:<n>`, `n` counting every creation.
///
/// **Links.** Each is made from the connection the store holds at that moment, so an
/// edited host or token is used by the next attempt; a connection gone from the store
/// ends the pane in `refused("Connection removed")`. A lost link is replaced on the
/// same bridge (`reconnect(with:)`), never with a new surface. Which link and when is
/// `RemoteReconnectPolicy`'s.
///
/// **Ends.** `sessionEnded` keeps the bridge, the helper and the surface, so the last
/// screen stays. A refusal (and a surface or bridge that could not be made, and a
/// helper that went away) keeps nothing: the bridge is stopped and the surface
/// destroyed at once.
///
/// **Threads.** The byte path is the bridge's and the link's, off the main actor. What
/// the link's thread reports (snapshot, resize, end) and the bridge's helper thread
/// reports (helper gone) reaches this type through `toMain`, asynchronously and never
/// waiting, in the stream's order; each is checked against the current link's
/// generation and against `close()`.
@MainActor
@Observable
final class RemotePane {
    typealias Cancel = @MainActor () -> Void

    /// Everything a pane is given; the app's are `RemotePanes.init(host:helperPath:connections:)`'s.
    struct Dependencies {
        var host: any ViewerSurfaceHosting
        /// The bundled `wietty-pty`.
        var helperPath: String
        /// The connection the store holds now, nil when it is gone.
        var connection: @MainActor (UUID) -> RemoteConnection?
        /// A link to that connection's session; a `RemoteSocketLink` in the app.
        var makeLink: @MainActor (RemoteConnection, String) -> any TerminalStreamLink
        /// A bridge listening on a socket of its own, with its first link.
        var makeBridge: @MainActor (any TerminalStreamLink) throws -> any ViewerBridging
        /// A monotonic clock in seconds.
        var now: @MainActor () -> TimeInterval
        /// Runs the work on the main actor after so many seconds, unless cancelled.
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancel
        /// From any thread to the main actor, asynchronously, in order with `nextTurn`.
        var toMain: @Sendable (@escaping @Sendable @MainActor () -> Void) -> Void
        /// On a later main turn, queued behind everything queued so far.
        var nextTurn: @MainActor (@escaping @MainActor () -> Void) -> Void
    }

    private static let log = Logger(subsystem: "eu.kloosterman.wietty", category: "remote-pane")

    /// What is shown when the pane cannot be made at all.
    static let surfaceFailedText = "The terminal could not be shown on this Mac."
    /// What is shown when the helper between the surface and the bridge went away.
    static let helperGoneText = "The terminal's view on this Mac stopped."

    /// Viewer surface ids, process wide, on the main actor.
    private static var lastCreation = 0

    let ref: RemoteSessionRef

    /// What the pane shows; see `RemoteReconnectPolicy.State`.
    private(set) var state: RemoteReconnectPolicy.State = .connecting
    /// The viewer surface while it exists.
    private(set) var surfaceId: String?

    private let dependencies: Dependencies
    private let gate: ViewerSurfaceGate
    @ObservationIgnored private var policy = RemoteReconnectPolicy()
    @ObservationIgnored private var bridge: (any ViewerBridging)?
    @ObservationIgnored private var grid: OwnPaneGrid?
    /// The generation of the current link; what an older one reports is dropped.
    @ObservationIgnored private var generation = 0
    /// The current link has been made and has not ended.
    @ObservationIgnored private var linkOut = false
    @ObservationIgnored private var timer: Cancel?
    /// The attempt timeout of the current link, and the generation it is for.
    @ObservationIgnored private var watchdog: Cancel?
    @ObservationIgnored private var watchdogGeneration: Int?
    @ObservationIgnored private var closed = false
    /// The current link, whose held snapshot this pane releases.
    @ObservationIgnored private var currentLink: ObservedLink?
    /// The grid the view was last given (`impose`), nil for the pane's own size.
    @ObservationIgnored private var shownGrid: TerminalSize?
    /// A snapshot of the current link held until the surface has `target`.
    @ObservationIgnored private var heldSnapshot: (token: Int, target: TerminalSize)?
    @ObservationIgnored private var holdLimit: Cancel?

    /// How long a snapshot is held at most for the surface to take the grid the view
    /// was given; past it the snapshot is passed on anyway.
    static let snapshotHoldLimit: TimeInterval = 1

    /// How long a link may take from being handed to the bridge to its first snapshot
    /// before it counts as lost. For the first link this runs from the show, so it also
    /// covers a helper that never connects to the bridge (no link is ever started).
    static let attemptTimeout: TimeInterval = 15

    init(ref: RemoteSessionRef, dependencies: Dependencies, gate: ViewerSurfaceGate) {
        self.ref = ref
        self.dependencies = dependencies
        self.gate = gate
    }

    /// The view of the surface, for the pane's container. Nil before the surface is
    /// made, after a refusal and after `close()`.
    var surfaceView: NSView? { surfaceId.flatMap { dependencies.host.view(id: $0) } }

    /// Makes the surface, its bridge and the first link, on a later main turn. Only
    /// `RemotePanes` calls it, once.
    fileprivate func start() {
        gate.afterDestroys { [weak self] in self?.show() }
    }

    /// The reconnect button: in `reconnecting` an attempt now, in `waiting` an attempt
    /// now and a new 2 minutes. Nothing in any other state.
    func reconnectPressed() {
        guard !closed else { return }
        let step = policy.reconnectPressed(now: dependencies.now())
        guard step != .none else { return }
        cancelTimer()
        publish()
        carryOut(step)
    }

    /// Stops the timers, the grid and the bridge (which stops the link), and destroys
    /// the surface. Idempotent. Nothing of this pane runs after it; the helper exits as
    /// its socket closes. Only `RemotePanes` calls it, when the last open of the pane
    /// is closed, so a pane SwiftUI still shows is never closed under it.
    fileprivate func close() {
        guard !closed else { return }
        closed = true
        tearDown()
    }

    // MARK: Showing

    private func show() {
        guard !closed else { return }
        guard let connection = dependencies.connection(ref.connectionId) else {
            policy.connectionRemoved()
            publish()
            return
        }
        let bridge: any ViewerBridging
        do {
            bridge = try dependencies.makeBridge(makeLink(connection))
        } catch {
            Self.log.error("no bridge for a remote pane: \(String(describing: error), privacy: .public)")
            fail(Self.surfaceFailedText)
            return
        }
        // Claims made between a link's end and the grid's reset never reach the next
        // link (see `TerminalBridge.holdsClaimsUntilReset`), as for the own pane.
        bridge.holdsClaimsUntilReset = true
        let toMain = dependencies.toMain
        bridge.onHelperGone = { [weak self] in
            toMain { [weak self] in self?.helperGone() }
        }
        self.bridge = bridge

        Self.lastCreation += 1
        let id = "rv:\(ref.connectionId.uuidString):\(ref.sessionId):\(Self.lastCreation)"
        let host = dependencies.host
        let grid = OwnPaneGrid(viewer: true, claim: { [weak bridge] size in
            bridge?.claim(cols: size.cols, rows: size.rows) ?? false
        }, resetClaims: { [weak bridge] in
            bridge?.resetClaims()
        }, impose: { [weak host, weak self] size in
            host?.impose(grid: size, on: id)
            self?.imposed(size)
        })
        self.grid = grid
        do {
            try host.createViewerSurface(id: id,
                                         command: PaneBridges.command(helper: dependencies.helperPath,
                                                                      socket: bridge.helperSocketPath),
                                         grid: grid)
        } catch {
            Self.log.error("no viewer surface for a remote pane: \(String(describing: error), privacy: .public)")
            fail(Self.surfaceFailedText)
            return
        }
        surfaceId = id
        host.observeViewerGrid(id: id) { [weak self] reported in self?.surfaceReported(reported) }
        armWatchdog()
    }

    /// A new link to `connection`, observed under a new generation.
    private func makeLink(_ connection: RemoteConnection) -> any TerminalStreamLink {
        generation += 1
        linkOut = true
        let tag = generation
        let toMain = dependencies.toMain
        let link = ObservedLink(dependencies.makeLink(connection, ref.sessionId),
                                holdsSnapshots: true) { [weak self] event in
            toMain { [weak self] in self?.linkReported(event, generation: tag) }
        }
        currentLink = link
        return link
    }

    // MARK: What the link and the bridge report, on the main actor

    private func linkReported(_ event: ObservedLink.Event, generation tag: Int) {
        guard !closed, tag == generation else { return }
        switch event {
        case .snapshot:
            cancelWatchdog()
            policy.snapshotDelivered(now: dependencies.now())
            publish()
        case let .resize(size, own):
            grid?.resizeReceived(size, own: own)
        case .snapshotWaiting(let token):
            // After the `resize` before it on this link: the hops keep the link's order,
            // so the grid has decided what the view shows, and imposed it.
            snapshotWaiting(token: token)
        case .ended(let reason):
            cancelWatchdog()
            linkOut = false
            if reason == .connectionLost {
                // The bridge holds claims from the end until this reset.
                grid?.linkLost()
            }
            let step = policy.linkEnded(reason, now: dependencies.now())
            publish()
            carryOut(step)
        }
    }

    /// The current link took longer than `attemptTimeout` to deliver its snapshot: it
    /// counts as lost. It is retired as a replaced link is (the bridge is handed an
    /// inert link, which stops it, so nothing more of it reaches the helper), and the
    /// policy proceeds as on any lost connection.
    private func attemptTimedOut() {
        guard !closed, !policy.isFinal, let bridge else { return }
        watchdog = nil
        watchdogGeneration = nil
        Self.log.error("a link of a remote pane delivered no snapshot within \(Self.attemptTimeout) s")
        dropHeldSnapshot()
        currentLink = nil
        // A new generation, so whatever the retired link still reports is dropped.
        generation += 1
        // Claims made from here go to the inert link and are never answered: the next
        // attempt resets the grid's count after it replaces this link (`attempt()`).
        linkOut = true
        bridge.reconnect(with: InertLink())
        // After the reconnect: an end of the retired link that marked the bridge's
        // claims held before it is cleared here.
        grid?.linkLost()
        let step = policy.linkEnded(.connectionLost, now: dependencies.now())
        publish()
        carryOut(step)
    }

    private func helperGone() {
        guard !closed, bridge != nil else { return }
        Self.log.error("the helper of a remote pane went away")
        if policy.isFinal {
            cancelWatchdog()
            bridge?.stop()
            bridge = nil
        } else {
            fail(Self.helperGoneText)
        }
    }

    // MARK: Carrying out the policy

    private func carryOut(_ step: RemoteReconnectPolicy.Step) {
        switch step {
        case .none:
            break
        case .attempt(let after) where after <= 0:
            attempt()
        case .attempt(let after):
            cancelTimer()
            timer = dependencies.schedule(after) { [weak self] in
                guard let self, !self.closed else { return }
                self.timer = nil
                self.attempt()
            }
        }
        afterStateChange()
    }

    /// A new link on the same bridge, from the connection the store holds now.
    private func attempt() {
        guard !closed, !policy.isFinal, let bridge else { return }
        guard let connection = dependencies.connection(ref.connectionId) else {
            policy.connectionRemoved()
            publish()
            afterStateChange()
            return
        }
        let replacing = linkOut
        // The replaced link's stop drops it too; this also forgets the hold here.
        dropHeldSnapshot()
        bridge.reconnect(with: makeLink(connection))
        if replacing {
            // Replacing a link that has not ended: the grid's count starts over as on
            // a loss, since a claim sent to it may never be answered. After the
            // reconnect, not before: the old link may end between the two, and the
            // bridge then holds claims until a reset, which must come after that end.
            // Once the reconnect has returned the old link is no longer the bridge's,
            // and its end holds nothing.
            grid?.linkLost()
        }
        armWatchdog()
    }

    /// What a final state keeps: after `ended` the bridge, helper and surface (the
    /// last screen stays) and nothing more is claimed; after `refused` nothing.
    private func afterStateChange() {
        switch policy.state {
        case .ended:
            cancelTimer()
            cancelWatchdog()
            grid?.stop()
        case .refused:
            tearDown()
        case .connecting, .live, .reconnecting, .waiting:
            break
        }
    }

    private func fail(_ message: String) {
        policy.failed(message)
        publish()
        tearDown()
    }

    private func tearDown() {
        cancelTimer()
        cancelWatchdog()
        // Before the bridge's stop, which stops the link and waits for its callback.
        dropHeldSnapshot()
        grid?.stop()
        grid = nil
        bridge?.stop()
        bridge = nil
        if let id = surfaceId {
            surfaceId = nil
            gate.destroy(id)
        }
    }

    // MARK: The held snapshot

    /// The current link holds a snapshot. Passed on at once when the view shows the
    /// pane's own size or the surface already has the grid the view was given; else when
    /// the surface reports that grid, or after `snapshotHoldLimit`.
    private func snapshotWaiting(token: Int) {
        dropHeldSnapshot()
        guard let target = shownGrid, let id = surfaceId, dependencies.host.size(id: id) != target else {
            currentLink?.releaseSnapshot(token: token, pass: true)
            return
        }
        heldSnapshot = (token, target)
        holdLimit = dependencies.schedule(Self.snapshotHoldLimit) { [weak self] in
            guard let self, !self.closed, let held = self.heldSnapshot, held.token == token else { return }
            Self.log.error("""
                a remote pane's surface did not reach \(held.target.cols)x\(held.target.rows) \
                within \(Self.snapshotHoldLimit) s; its snapshot is passed on anyway
                """)
            self.holdLimit = nil
            self.passHeldSnapshot()
        }
    }

    /// The grid handed to the view changed (`OwnPaneGrid` imposed it).
    private func imposed(_ size: TerminalSize?) {
        shownGrid = size
        guard let held = heldSnapshot else { return }
        if let size, let id = surfaceId, dependencies.host.size(id: id) != size {
            heldSnapshot = (held.token, size)
        } else {
            passHeldSnapshot()
        }
    }

    /// The surface reported its grid.
    private func surfaceReported(_ size: TerminalSize) {
        guard !closed, let held = heldSnapshot, held.target == size else { return }
        passHeldSnapshot()
    }

    private func passHeldSnapshot() {
        guard let held = heldSnapshot else { return }
        heldSnapshot = nil
        holdLimit?()
        holdLimit = nil
        currentLink?.releaseSnapshot(token: held.token, pass: true)
    }

    private func dropHeldSnapshot() {
        holdLimit?()
        holdLimit = nil
        guard let held = heldSnapshot else { return }
        heldSnapshot = nil
        currentLink?.releaseSnapshot(token: held.token, pass: false)
    }

    /// Starts the attempt timeout of the current link, replacing any earlier one.
    private func armWatchdog() {
        cancelWatchdog()
        let tag = generation
        watchdogGeneration = tag
        watchdog = dependencies.schedule(Self.attemptTimeout) { [weak self] in
            guard let self, !self.closed, self.watchdogGeneration == tag, self.generation == tag else { return }
            self.attemptTimedOut()
        }
    }

    private func cancelWatchdog() {
        watchdog?()
        watchdog = nil
        watchdogGeneration = nil
    }

    private func cancelTimer() {
        timer?()
        timer = nil
    }

    private func publish() {
        if state != policy.state { state = policy.state }
    }
}

/// Where every viewer surface is destroyed, and what holds a create back until a main
/// turn queued after the last destroy.
///
/// A create is put on the next main turn; if a destroy ran between that and the turn,
/// it is put on the turn after that destroy instead. So however panes are closed and
/// opened (one closing and another opening in the same turn, or a refusal's destroy
/// landing between an open and its turn), a viewer surface is created in a turn queued
/// after every viewer surface destroy before it.
@MainActor
final class ViewerSurfaceGate {
    private let host: any ViewerSurfaceHosting
    private let nextTurn: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var destroys = 0

    init(host: any ViewerSurfaceHosting,
         nextTurn: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) {
        self.host = host
        self.nextTurn = nextTurn
    }

    func destroy(_ id: String) {
        host.destroySurface(id: id)
        destroys += 1
    }

    /// Runs `work` on a main turn queued after every destroy made through this gate.
    func afterDestroys(_ work: @escaping @MainActor () -> Void) {
        let seen = destroys
        nextTurn { [weak self] in
            guard let self else { return }
            if destroys == seen { work() } else { afterDestroys(work) }
        }
    }
}

/// The panes of terminals on other Macs that are shown, keyed by connection and
/// session: one today, the one in the main window's pane.
///
/// `open` when a pane appears, `close` when it disappears (counted per ref), `closeAll`
/// at quit, before the surface host is freed.
@MainActor
final class RemotePanes {
    private let dependencies: RemotePane.Dependencies
    private let gate: ViewerSurfaceGate
    private var panes: [RemoteSessionRef: (pane: RemotePane, opens: Int)] = [:]
    /// Set by `closeAll`; every later `open` is inert.
    private var closedAll = false

    init(dependencies: RemotePane.Dependencies) {
        self.dependencies = dependencies
        gate = ViewerSurfaceGate(host: dependencies.host, nextTurn: dependencies.nextTurn)
    }

    /// The app's (`RemotePane.Dependencies.app`).
    convenience init(host: GhosttySurfaceHost, helperPath: String, connections: RemoteConnectionsStore) {
        self.init(dependencies: .app(host: host, helperPath: helperPath, connections: connections))
    }

    /// How many panes are open. For tests.
    var count: Int { panes.count }

    /// The pane of `ref`, made and started if it is not open. Counted: a view that
    /// appears for a ref still open (SwiftUI may run a new view's appear before the old
    /// one's disappear) gets the same pane, and it stays until each open is closed.
    ///
    /// After `closeAll` (quit) nothing opens: a view that appears that late gets a pane
    /// that is closed already, is not kept, makes nothing and whose close is nothing.
    @discardableResult
    func open(_ ref: RemoteSessionRef) -> RemotePane {
        if closedAll {
            let inert = RemotePane(ref: ref, dependencies: dependencies, gate: gate)
            inert.close()
            return inert
        }
        if let entry = panes[ref] {
            panes[ref] = (entry.pane, entry.opens + 1)
            return entry.pane
        }
        let pane = RemotePane(ref: ref, dependencies: dependencies, gate: gate)
        panes[ref] = (pane, 1)
        pane.start()
        return pane
    }

    /// The pane of `ref` while it is open.
    func pane(for ref: RemoteSessionRef) -> RemotePane? { panes[ref]?.pane }

    /// How many opens of `ref` are not closed yet. For tests.
    func opens(of ref: RemoteSessionRef) -> Int { panes[ref]?.opens ?? 0 }

    /// One close for one `open`: the pane is closed (and forgotten, so a later `open`
    /// makes a new one) when its last open is closed. Nothing to do for one that is
    /// not open.
    func close(_ ref: RemoteSessionRef) {
        guard let entry = panes[ref] else { return }
        if entry.opens > 1 {
            panes[ref] = (entry.pane, entry.opens - 1)
        } else {
            panes[ref] = nil
            entry.pane.close()
        }
    }

    /// Closes every pane, whatever its count, and refuses every later `open`. For quit.
    func closeAll() {
        closedAll = true
        let all = panes.values.map(\.pane)
        panes = [:]
        for pane in all { pane.close() }
    }
}

extension RemotePane.Dependencies {
    /// The app's: `host`'s viewer surfaces, `wietty-pty` at `helperPath`, each link a
    /// `RemoteSocketLink` to the connection `connections` holds then, each bridge a
    /// `TerminalBridge` on a socket of its own, the main queue and the system's uptime.
    @MainActor
    static func app(host: any ViewerSurfaceHosting, helperPath: String,
                    connections: RemoteConnectionsStore) -> Self {
        Self(
            host: host,
            helperPath: helperPath,
            connection: { [weak connections] id in connections?.connections.first { $0.id == id } },
            makeLink: { connection, session in RemoteSocketLink(connection: connection, session: session) },
            makeBridge: { link in
                try TerminalBridge(helperSocketPath: LocalSocketPaths.bridge(PaneBridges.nextSequence()),
                                   link: link)
            },
            now: { ProcessInfo.processInfo.systemUptime },
            schedule: { delay, work in
                let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            },
            toMain: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } },
            nextTurn: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } })
    }
}
