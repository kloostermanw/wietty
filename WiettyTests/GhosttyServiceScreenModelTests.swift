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
    private var overtook = 0
    /// How many bytes the hub had been handed, asked at the moment of each write.
    private let hubCount: @Sendable () -> Int

    init(size: TerminalSize, hubCount: @escaping @Sendable () -> Int = { .max }) {
        grid = size
        self.hubCount = hubCount
    }

    var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return written }
    /// Writes that arrived holding bytes the hub had not been handed yet.
    var writesAheadOfTheHub: Int { lock.lock(); defer { lock.unlock() }; return overtook }

    func write(_ bytes: [UInt8]) {
        let handed = hubCount()
        lock.lock(); defer { lock.unlock() }
        written += bytes
        if written.count > handed { overtook += 1 }
    }

    func resize(to size: TerminalSize) { lock.lock(); grid = size; lock.unlock() }
    var size: TerminalSize { lock.lock(); defer { lock.unlock() }; return grid }
    func paintFrame() -> [UInt8] { [] }
    func snapshot() -> Data { Data() }
    func text(maxLines: Int) -> String { String(decoding: bytes, as: UTF8.self) }
}

/// What the service asked its factory for. Weak, because whether the service is
/// the only thing keeping a model alive is one of the things under test.
@MainActor private final class ModelFactoryLog {
    private(set) var sizes: [TerminalSize] = []
    weak var last: RecordingScreenModel?
    var hubCount: @Sendable () -> Int = { .max }
    var failure: (any Error)?

    func make(_ size: TerminalSize) throws -> any TerminalScreenModel {
        sizes.append(size)
        if let failure { throw failure }
        let model = RecordingScreenModel(size: size, hubCount: hubCount)
        last = model
        return model
    }
}

/// The service keeping one screen model per terminal: made when a terminal opens,
/// fed everything the terminal prints, resized with the surface, and released
/// when the terminal is torn down.
///
/// Nothing in the app reads a model yet. These pin that it is there and correct
/// to read, which is what switching the readers over will rest on.
@MainActor
@Suite struct GhosttyServiceScreenModelTests {
    private static let folder = URL(fileURLWithPath: "/tmp")

    /// A service on the real model, as the app builds it.
    private func service(_ host: FakeSurfaceHost) -> GhosttyService {
        GhosttyService(host: host, helperPath: "/usr/bin/true",
                       onOutput: { _, _ in }, onTerminated: { _ in })
    }

    /// A service whose models are the recording kind.
    private func service(_ host: FakeSurfaceHost, models: ModelFactoryLog,
                         onOutput: @escaping @Sendable (String, [UInt8]) -> Void = { _, _ in })
        -> GhosttyService {
        GhosttyService(host: host, helperPath: "/usr/bin/true",
                       onOutput: onOutput,
                       makeScreenModel: { try models.make($0) },
                       onTerminated: { _ in })
    }

    private func open(_ service: GhosttyService, _ command: String?) async throws -> String {
        try await service.open(folder: Self.folder, existingWindowId: nil,
                               command: command, badge: nil).sessionId
    }

    // MARK: - Feeding

    /// The same bytes the hub gets, all of them and in the same order, and never
    /// ahead of the hub: a viewer that is already attached must not wait for a
    /// parse it gains nothing from.
    @Test func aTerminalsOutputReachesItsModelInOrderAfterTheHub() async throws {
        let host = FakeSurfaceHost()
        let hub = ByteSink()
        let models = ModelFactoryLog()
        models.hubCount = { hub.count }
        let service = service(host, models: models, onOutput: { _, bytes in hub.append(bytes) })
        defer { service.closeAll() }
        let session = try await open(service, "for i in 1 2 3 4 5 6 7 8; do echo line-$((i * 11)); done")
        let model = try #require(service.screenModel(for: session) as? RecordingScreenModel)
        try await waitUntil {
            model.text(maxLines: 0).contains("line-88") && model.bytes == hub.bytes
        }
        #expect(model.writesAheadOfTheHub == 0)
        let text = model.text(maxLines: 0)
        let positions = (1...8).compactMap { text.range(of: "line-\($0 * 11)")?.lowerBound }
        #expect(positions.count == 8)
        #expect(positions == positions.sorted())
    }

    /// End to end on the real model: what a shell prints is on the screen the core
    /// holds, with no surface involved in reading it back.
    @Test func theModelHoldsWhatTheTerminalPrinted() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let session = try await open(service, "echo tagged-$((6+7))")
        try await waitUntil {
            service.screenModel(for: session)?.text(maxLines: 50).contains("tagged-13") ?? false
        }
        #expect(service.screenModel(for: session)?.paintFrame().isEmpty == false)
    }

    @Test func twoTerminalsDoNotShareAModel() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
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

        let real = service(host)
        defer { real.closeAll() }
        let session = try await open(real, "sleep 5")
        #expect(real.screenModel(for: session)?.size == GhosttyService.initialSize)
    }

    /// The surface decides the grid and the model follows, on the same report that
    /// resizes the pty.
    @Test func aSurfaceResizeReachesTheModel() async throws {
        let host = FakeSurfaceHost()
        let service = service(host)
        defer { service.closeAll() }
        let session = try await open(service, "sleep 5")
        let other = try await open(service, "sleep 5")
        host.emitResize(session, TerminalSize(cols: 111, rows: 41))
        #expect(service.screenModel(for: session)?.size == TerminalSize(cols: 111, rows: 41))
        // Its own terminal only.
        #expect(service.screenModel(for: other)?.size == GhosttyService.initialSize)
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
        let service = service(host)
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
