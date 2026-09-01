import Testing
import Foundation
@testable import Wietty

final class FakeFreshnessProvider: FreshnessChecking, @unchecked Sendable {
    var results: [FreshnessResult] = []
    /// The cache this provider hands back, so a store test can assert the store keeps
    /// and re-passes it. Defaults to empty, matching a provider that caches nothing.
    var returnedCache: FreshnessCache = [:]
    private(set) var lastChecks: [String: CheckConfig] = [:]
    private(set) var lastCache: FreshnessCache = [:]
    private(set) var lastShellInit: [String] = []
    private(set) var runCount = 0

    func run(checks: [String: CheckConfig], in folder: URL, cache: FreshnessCache, shellInit: [String])
        async -> (results: [FreshnessResult], cache: FreshnessCache) {
        lastChecks = checks
        lastCache = cache
        lastShellInit = shellInit
        runCount += 1
        return (results, returnedCache)
    }
}

@Suite @MainActor struct FreshnessStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ fresh: FakeFreshnessProvider) -> ProjectStore {
        ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(),
                     gitProvider: FakeGitInfoProvider(), freshProvider: fresh)
    }

    @Test func refreshRunsConfiguredChecksAndStoresResults() async {
        let fresh = FakeFreshnessProvider()
        fresh.results = [FreshnessResult(name: "composer", actionNeeded: true, message: "run composer install")]
        let store = store(fresh)
        store.addProject(url: makeTempFolder(named: "proj"))
        let id = store.projects[0].id
        store.addCheck(name: "composer", config: CheckConfig(command: "check"), for: id)

        await store.refreshAllGitInfo()

        #expect(fresh.lastChecks["composer"]?.command == "check")
        #expect(store.freshness[id]?.first?.actionNeeded == true)
        #expect(store.freshness[id].map(\.needsAttention) == true)
    }

    /// The store hands the workspace's `shell_init` to the provider, so a check runs
    /// with the same shell lines a process or test does.
    @Test func passesWorkspaceShellInitToProvider() async {
        let fresh = FakeFreshnessProvider()
        fresh.results = [FreshnessResult(name: "composer", actionNeeded: false, message: "composer")]
        let store = store(fresh)
        store.addProject(url: makeTempFolder(named: "proj"))
        let id = store.projects[0].id
        store.addCheck(name: "composer", config: CheckConfig(command: "check"), for: id)
        store.setShellInit(["export PATH=/opt/bin:$PATH"], for: id)

        await store.refreshAllGitInfo()

        #expect(fresh.lastShellInit == ["export PATH=/opt/bin:$PATH"])
    }

    /// The store keeps each workspace's freshness cache and passes it back into the
    /// next tick, so a `watch` check can skip re-running while its file is unchanged.
    @Test func carriesFreshnessCacheAcrossTicks() async {
        let fresh = FakeFreshnessProvider()
        let result = FreshnessResult(name: "c", actionNeeded: false, message: "c")
        fresh.results = [result]
        fresh.returnedCache = ["c": FreshnessCacheEntry(watchHash: "h", command: "check", result: result)]
        let store = store(fresh)
        store.addProject(url: makeTempFolder(named: "proj"))
        let id = store.projects[0].id
        store.addCheck(name: "c", config: CheckConfig(command: "check", watch: "composer.lock"), for: id)

        await store.refreshAllGitInfo()
        #expect(fresh.lastCache.isEmpty)

        await store.refreshAllGitInfo()
        #expect(fresh.lastCache["c"]?.watchHash == "h")
    }

    /// A workspace with no configured checks never calls the provider and shows no
    /// marker, so an untouched workspace is unaffected.
    @Test func noConfiguredChecksMeansNoRunAndNoResults() async {
        let fresh = FakeFreshnessProvider()
        fresh.results = [FreshnessResult(name: "x", actionNeeded: true, message: "x")]
        let store = store(fresh)
        store.addProject(url: makeTempFolder(named: "proj"))
        let id = store.projects[0].id

        await store.refreshAllGitInfo()

        #expect(fresh.runCount == 0)
        #expect(store.freshness[id] == nil)
    }

    @Test func removingProjectClearsFreshness() async {
        let fresh = FakeFreshnessProvider()
        fresh.results = [FreshnessResult(name: "c", actionNeeded: true, message: "c")]
        let store = store(fresh)
        store.addProject(url: makeTempFolder(named: "proj"))
        let project = store.projects[0]
        store.addCheck(name: "c", config: CheckConfig(command: "check"), for: project.id)
        await store.refreshAllGitInfo()
        #expect(store.freshness[project.id] != nil)

        store.remove(project)
        #expect(store.freshness[project.id] == nil)
    }

    /// Removing a check drops its stored result so the marker stops asking for a
    /// check that no longer exists.
    @Test func removingCheckDropsItsResult() async {
        let fresh = FakeFreshnessProvider()
        fresh.results = [FreshnessResult(name: "c", actionNeeded: true, message: "c")]
        let store = store(fresh)
        store.addProject(url: makeTempFolder(named: "proj"))
        let id = store.projects[0].id
        store.addCheck(name: "c", config: CheckConfig(command: "check"), for: id)
        await store.refreshAllGitInfo()
        #expect(store.freshness[id]?.isEmpty == false)

        store.removeCheck(name: "c", for: id)
        #expect(store.freshness[id]?.contains { $0.name == "c" } != true)
        #expect(store.projects[0].configChecks == nil)
    }

    /// The mutators mirror the test mutators: add, rename-via-update, and refuse a
    /// duplicate name.
    @Test func checkMutatorsAddUpdateAndRefuseDuplicates() {
        let store = store(FakeFreshnessProvider())
        store.addProject(url: makeTempFolder(named: "proj"))
        let id = store.projects[0].id

        #expect(store.addCheck(name: "composer", config: CheckConfig(command: "a"), for: id) == true)
        #expect(store.addCheck(name: "composer", config: CheckConfig(command: "b"), for: id) == false)
        #expect(store.updateCheck(originalName: "composer", name: "npm",
                                  config: CheckConfig(command: "c"), for: id) == true)
        #expect(store.projects[0].configChecks?["npm"]?.command == "c")
        #expect(store.projects[0].configChecks?["composer"] == nil)
    }
}
