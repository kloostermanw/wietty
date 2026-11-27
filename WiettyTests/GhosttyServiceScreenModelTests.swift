import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Every byte the service handed the hub, in order. Lock guarded for the reason
/// `GhosttyServiceTests` gives for its own sinks: the output handler is
/// `@Sendable` and runs on the relay's queue.
private final class ByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8] = []
    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    func append(_ bytes: [UInt8]) { lock.lock(); storage += bytes; lock.unlock() }
}

/// A `TerminalScreenModel` that parses nothing and remembers everything it was
/// told, so a test can assert what the service did rather than what a terminal
/// emulator made of it.
private final class RecordingScreenModel: TerminalScreenModel, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [UInt8] = []
    private var grid: TerminalSize

    init(size: TerminalSize) { grid = size }

    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return written }

    func write(_ bytes: [UInt8]) { lock.lock(); written += bytes; lock.unlock() }
    func resize(to size: TerminalSize) { lock.lock(); grid = size; lock.unlock() }
    var size: TerminalSize { lock.lock(); defer { lock.unlock() }; return grid }
    func paintFrame() -> [UInt8] { [] }
    func snapshotFrame() -> TerminalSnapshotFrame {
        TerminalSnapshotFrame(size: size, bytes: [], alternate: false)
    }
    var isAlternateScreen: Bool { false }
    func snapshot() -> Data { Data() }
    func text(maxLines: Int) -> String { String(decoding: bytes, as: UTF8.self) }
}

/// What the service asked its factory for. Weak, because whether the service is
/// the only thing keeping a model alive is one of the things under test.
@MainActor private final class ModelFactoryLog {
    private(set) var sizes: [TerminalSize] = []
    private(set) var clustering: [Bool] = []
    private(set) var scrollback: [Int] = []
    weak var last: RecordingScreenModel?
    var failure: (any Error)?

    func make(_ size: TerminalSize, _ scrollbackLines: Int,
              _ graphemeClustering: Bool) throws -> any TerminalScreenModel {
        sizes.append(size)
        scrollback.append(scrollbackLines)
        clustering.append(graphemeClustering)
        if let failure { throw failure }
        let model = RecordingScreenModel(size: size)
        last = model
        return model
    }
}

/// The service keeping one screen model per terminal: made when a terminal opens,
/// fed everything the terminal prints, resized with the surface, and released
/// when the terminal is torn down.
@MainActor
@Suite struct GhosttyServiceScreenModelTests {
    private static let folder = URL(fileURLWithPath: "/tmp")

    /// A service on the real model, wired as the app wires it. Through the stack,
    /// because the service does not write a model itself: the hub does, in the
    /// step that accepts a chunk, and the stack is what connects the two. The
    /// service keeps the hub alive through the hooks it was built with.
    private func service(_ host: FakeSurfaceHost) throws -> GhosttyService {
        try #require(GhosttyStack.testing(host: host).ghosttyService)
    }

    /// A service whose models are the recording kind.
    private func service(_ host: FakeSurfaceHost, models: ModelFactoryLog,
                         onOutput: @escaping @Sendable (String, [UInt8]) -> Void = { _, _ in })
        -> GhosttyService {
        GhosttyService(host: host, readDelay: 0,
                       onOutput: onOutput,
                       makeScreenModel: { try models.make($0, $1, $2) },
                       onTerminated: { _ in })
    }

    private func open(_ service: GhosttyService, _ command: String?) async throws -> String {
        try await service.open(folder: Self.folder, existingWindowId: nil,
                               command: command).sessionId
    }

    // MARK: - Scrollback limit

    /// With nothing wired, a terminal's model is built with the default limit.
    @Test func aModelIsBuiltWithTheDefaultScrollbackWhenNothingSaysOtherwise() async throws {
        let models = ModelFactoryLog()
        let service = service(FakeSurfaceHost(), models: models)
        defer { service.closeAll() }
        _ = try await open(service, "sleep 30")
        #expect(models.scrollback == [TerminalScrollback.defaultLines])
    }

    /// The limit is asked for when a terminal opens, once. A terminal opened after
    /// the setting changed gets a model with the new limit, and the one that was
    /// already open keeps the model it had: nothing is rebuilt or resized.
    @Test func aTerminalOpenedAfterAChangeGetsAModelWithTheNewLimit() async throws {
        let models = ModelFactoryLog()
        let service = service(FakeSurfaceHost(), models: models)
        defer { service.closeAll() }
        var limit = 4_000
        service.scrollbackLines = { limit }
        let first = try await open(service, "sleep 30")
        let firstModel = try #require(service.screenModel(for: first))
        limit = 25_000
        _ = try await open(service, "sleep 30")
        #expect(models.scrollback == [4_000, 25_000])
        #expect(service.screenModel(for: first) === firstModel)
    }

    /// Whatever answers, a model is never built outside the documented range.
    @Test func aLimitOutsideTheRangeIsClampedBeforeAModelIsBuilt() async throws {
        let models = ModelFactoryLog()
        let service = service(FakeSurfaceHost(), models: models)
        defer { service.closeAll() }
        service.scrollbackLines = { 0 }
        _ = try await open(service, "sleep 30")
        service.scrollbackLines = { .max }
        _ = try await open(service, "sleep 30")
        #expect(models.scrollback == [TerminalScrollback.range.lowerBound,
                                      TerminalScrollback.range.upperBound])
    }

    /// The stack is what points the service at the store, and it follows the
    /// store rather than copying it: a later change is what the next open reads.
    @Test func theStackMakesTheServiceFollowTheStoresSetting() throws {
        let stack = GhosttyStack.testing(host: FakeSurfaceHost())
        defer { stack.shutDown() }
        let service = try #require(stack.ghosttyService)
        let store = SettingsFixture(config: WiettyConfigFile.temporary()).store
        #expect(service.scrollbackLines() == TerminalScrollback.defaultLines)
        stack.followScrollbackSetting(of: store)
        store.scrollbackLines = 3_000
        #expect(service.scrollbackLines() == 3_000)
        store.scrollbackLines = 50_000
        #expect(service.scrollbackLines() == 50_000)
    }

    // MARK: - Feeding

    /// The model gets the bytes the output hook was handed, all of them, in the
    /// same order and once. The service does not write the model beside the
    /// hook: whoever takes the output feeds it, which in the app is the hub, so
    /// that the model and the stream are at one offset. A second write here would
    /// put every byte on the screen twice.
    @Test func aTerminalsOutputReachesItsModelThroughTheOutputHookAndOnlyOnce() async throws {
        let host = FakeSurfaceHost()
        let handed = ByteSink()
        let models = ModelFactoryLog()
        let hub = PaneStreamHub()
        let service = service(host, models: models, onOutput: { session, bytes in
            handed.append(bytes)
            hub.write(session: session, bytes: bytes)
        })
        let shared = service.shared
        hub.onIngest = { session, bytes in shared.model(for: session)?.write(bytes) }
        defer { service.closeAll() }
        let session = try await open(service, "for i in 1 2 3 4 5 6 7 8; do echo line-$((i * 11)); done")
        let model = try #require(service.screenModel(for: session) as? RecordingScreenModel)
        try await waitUntil {
            model.text(maxLines: 0).contains("line-88") && model.bytes == handed.bytes
        }
        let text = model.text(maxLines: 0)
        let positions = (1...8).compactMap { text.range(of: "line-\($0 * 11)")?.lowerBound }
        #expect(positions.count == 8)
        #expect(positions == positions.sorted())
    }

    /// And with nobody taking the output, nothing reaches the model. Not a
    /// feature, a boundary: it is what says the service has no second path in.
    @Test func theServiceDoesNotWriteAModelItself() async throws {
        let host = FakeSurfaceHost()
        let handed = ByteSink()
        let models = ModelFactoryLog()
        let service = service(host, models: models, onOutput: { _, bytes in handed.append(bytes) })
        defer { service.closeAll() }
        let session = try await open(service, "echo unread-$((40+2))")
        let model = try #require(service.screenModel(for: session) as? RecordingScreenModel)
        try await waitUntil { String(decoding: handed.bytes, as: UTF8.self).contains("unread-42") }
        #expect(model.bytes.isEmpty)
    }

    /// End to end on the real model: what a shell prints is on the screen the core
    /// holds, with no surface involved in reading it back.
    @Test func theModelHoldsWhatTheTerminalPrinted() async throws {
        let host = FakeSurfaceHost()
        let service = try service(host)
        defer { service.closeAll() }
        let session = try await open(service, "echo tagged-$((6+7))")
        try await waitUntil {
            service.screenModel(for: session)?.text(maxLines: 50).contains("tagged-13") ?? false
        }
        #expect(service.screenModel(for: session)?.paintFrame().isEmpty == false)
    }

    @Test func twoTerminalsDoNotShareAModel() async throws {
        let host = FakeSurfaceHost()
        let service = try service(host)
        defer { service.closeAll() }
        let first = try await open(service, "echo alpha-$((1+1)); sleep 5")
        let second = try await open(service, "echo beta-$((2+2)); sleep 5")
        let firstModel = try #require(service.screenModel(for: first))
        let secondModel = try #require(service.screenModel(for: second))
        #expect(firstModel !== secondModel)
        try await waitUntil {
            firstModel.text(maxLines: 50).contains("alpha-2")
                && secondModel.text(maxLines: 50).contains("beta-4")
        }
        #expect(!firstModel.text(maxLines: 50).contains("beta-4"))
        #expect(!secondModel.text(maxLines: 50).contains("alpha-2"))
    }

    // MARK: - The grid

    /// The pty is spawned at `initialSize` and so is the model, or the first lines
    /// a shell prints would be wrapped against one grid and parsed against another.
    @Test func aModelStartsAtTheGridTheTerminalIsOpenedWith() async throws {
        let host = FakeSurfaceHost()
        let models = ModelFactoryLog()
        let recording = service(host, models: models)
        defer { recording.closeAll() }
        _ = try await open(recording, "sleep 5")
        #expect(models.sizes == [GhosttyService.initialSize])

        let real = try service(host)
        defer { real.closeAll() }
        let session = try await open(real, "sleep 5")
        #expect(real.screenModel(for: session)?.size == GhosttyService.initialSize)
    }

    /// A surface's own grid report leaves the model where it is (decision P4). The
    /// resizer the service registered for a claim moves it, that terminal's only.
    @Test func aSurfaceReportAloneLeavesTheModelAndAClaimsResizerMovesIt() async throws {
        let host = FakeSurfaceHost()
        let service = try service(host)
        defer { service.closeAll() }
        let session = try await open(service, "sleep 5")
        let other = try await open(service, "sleep 5")
        host.emitResize(session, TerminalSize(cols: 111, rows: 41))
        #expect(service.screenModel(for: session)?.size == GhosttyService.initialSize)

        let resizer = try #require(service.shared.resizer(for: session))
        resizer(TerminalSize(cols: 111, rows: 41))
        #expect(service.screenModel(for: session)?.size == TerminalSize(cols: 111, rows: 41))
        // Its own terminal only.
        #expect(service.screenModel(for: other)?.size == GhosttyService.initialSize)
    }

    /// The setting that decides how many cells a joined emoji takes. A user whose
    /// Ghostty config says `legacy` has surfaces with mode 2027 off, and a model
    /// that kept it on would lay out every line holding such an emoji differently
    /// from the surface it mirrors. Read when the terminal opens, so a later
    /// terminal follows a setting that changed in between.
    @Test func aModelIsBuiltWithTheHostsGraphemeClustering() async throws {
        let host = FakeSurfaceHost()
        let models = ModelFactoryLog()
        let recording = service(host, models: models)
        defer { recording.closeAll() }
        _ = try await open(recording, "sleep 5")
        host.graphemeClustering = false
        _ = try await open(recording, "sleep 5")
        #expect(models.clustering == [true, false])
    }

    /// The same, through the real model. Four people joined into one emoji are
    /// one wide cell with clustering and four without, so what follows them is
    /// painted in a different column.
    @Test func aLegacyHostGivesAModelThatDoesNotClusterGraphemes() async throws {
        let bytes = Array("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}x".utf8)
        let host = FakeSurfaceHost()
        let service = try service(host)
        defer { service.closeAll() }
        let clustered = try #require(service.screenModel(for: try await open(service, "sleep 5")))
        host.graphemeClustering = false
        let legacy = try #require(service.screenModel(for: try await open(service, "sleep 5")))

        clustered.write(bytes)
        legacy.write(bytes)
        #expect(clustered.paintFrame() != legacy.paintFrame())

        // And only because of the setting: two terminals opened alike agree.
        let alsoLegacy = try #require(service.screenModel(for: try await open(service, "sleep 5")))
        alsoLegacy.write(bytes)
        #expect(alsoLegacy.paintFrame() == legacy.paintFrame())
    }

    // MARK: - Lifetime

    @Test func closingATerminalReleasesItsModel() async throws {
        let host = FakeSurfaceHost()
        let models = ModelFactoryLog()
        let service = service(host, models: models)
        defer { service.closeAll() }
        let session = try await open(service, "sleep 5")
        #expect(models.last != nil)
        try await service.close(sessionId: session)
        #expect(service.screenModel(for: session) == nil)
        // Gone, not merely unlisted: a full scrollback is megabytes per terminal.
        // Polled, because the relay that fed it finishes on its own queue.
        try await waitUntil { models.last == nil }
    }

    @Test func closingEverythingReleasesEveryModel() async throws {
        let host = FakeSurfaceHost()
        let models = ModelFactoryLog()
        let service = service(host, models: models)
        let first = try await open(service, "sleep 5")
        let second = try await open(service, "sleep 5")
        #expect(models.sizes.count == 2)
        service.closeAll()
        #expect(service.screenModel(for: first) == nil)
        #expect(service.screenModel(for: second) == nil)
        try await waitUntil { models.last == nil }
    }

    /// A terminal whose child exited keeps its surface so its last screen can be
    /// read, and keeps its model for the same reason. Reviving the row is what
    /// finishes with both.
    @Test func anExitedTerminalKeepsItsModelUntilItIsDiscarded() async throws {
        let host = FakeSurfaceHost()
        let service = try service(host)
        defer { service.closeAll() }
        let session = try await open(service, "echo last-$((20+2))")
        try await waitUntil { service.liveSessions.isEmpty }
        let model = try #require(service.screenModel(for: session))
        try await waitUntil { model.text(maxLines: 50).contains("last-22") }
        await service.discard(sessionId: session)
        #expect(service.screenModel(for: session) == nil)
    }

    @Test func aFailedSurfaceLeavesNoModel() async throws {
        let host = FakeSurfaceHost()
        host.failNextCreate = true
        let models = ModelFactoryLog()
        let service = service(host, models: models)
        defer { service.closeAll() }
        await #expect(throws: (any Error).self) { _ = try await open(service, nil) }
        // One was made, and nothing kept it.
        #expect(models.sizes.count == 1)
        try await waitUntil { models.last == nil }
    }

    /// A terminal without a model would be one the core cannot read, so the open
    /// fails instead, and it fails before anything was spawned.
    @Test func aModelThatCannotBeBuiltFailsTheOpen() async {
        let host = FakeSurfaceHost()
        let models = ModelFactoryLog()
        models.failure = GhosttyVtError.terminalFailed(code: -1)
        let service = service(host, models: models)
        defer { service.closeAll() }
        await #expect(throws: GhosttyVtError.terminalFailed(code: -1)) {
            _ = try await open(service, nil)
        }
        #expect(host.created.isEmpty)
        #expect(service.liveSessions.isEmpty)
    }

    /// Polls a condition instead of sleeping a fixed time, as `GhosttyServiceTests`
    /// does: a real shell reaching its first write is not an event a test can
    /// observe.
    private func waitUntil(timeout: Duration = .seconds(6),
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Bool(false), "condition never became true")
    }
}
