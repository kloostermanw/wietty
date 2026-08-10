import Testing
import Foundation
@testable import Wietty

private struct StubChecker: ReleaseChecking {
    let result: Result<GitHubRelease, any Error>
    func latestRelease() async throws -> GitHubRelease { try result.get() }
}

private struct ExplodingChecker: ReleaseChecking {
    func latestRelease() async throws -> GitHubRelease {
        Issue.record("checker should not be called")
        throw UpdateError.badResponse(-1)
    }
}

/// Returns a different result on each successive call, so a test can tell whether a
/// second `checkForUpdates` actually reached the network call or was short-circuited
/// before it.
private actor SequencedChecker: ReleaseChecking {
    private var calls = 0
    private let results: [Result<GitHubRelease, any Error>]

    init(_ results: [Result<GitHubRelease, any Error>]) {
        self.results = results
    }

    func latestRelease() async throws -> GitHubRelease {
        defer { calls += 1 }
        return try results[min(calls, results.count - 1)].get()
    }
}

private func release(tag: String) -> GitHubRelease {
    let json = """
    {"tag_name": "\(tag)", "name": "\(tag)", "body": "",
     "html_url": "https://github.com/kloostermanw/wietty/releases/tag/\(tag)",
     "assets": [{"name": "Wietty.dmg", "browser_download_url": "https://example.com/Wietty.dmg"}]}
    """
    return try! JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
}

private func freshDefaults() -> UserDefaults {
    let suite = "UpdateServiceTests-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

@MainActor
@Suite struct UpdateServiceTests {
    @Test func reportsAvailableWhenReleaseNewer() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(release(tag: "v1.1.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await service.checkForUpdates(userInitiated: true)
        #expect(service.state == .available(release(tag: "v1.1.0")))
    }

    @Test func reportsUpToDateWhenNotNewer() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(release(tag: "v1.0.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await service.checkForUpdates(userInitiated: true)
        #expect(service.state == .upToDate)
    }

    @Test func backgroundCheckStaysIdleWhenNotNewer() async {
        let service = UpdateService(
            checker: StubChecker(result: .success(release(tag: "v1.0.0"))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .idle)
    }

    @Test func backgroundCheckDoesNotDisturbAvailableState() async {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        // A second, distinct release result stands in for "what the network would say if
        // the background check actually ran": if the active-state guard didn't short-circuit
        // it, this result (not newer than currentVersion) would flip state to .idle. throttle
        // is 0 and `now` is fixed so the pre-existing throttle check can't be what blocks the
        // second call instead of the guard.
        let checker = SequencedChecker([
            .success(release(tag: "v1.1.0")),
            .success(release(tag: "v1.0.0"))
        ])
        let service = UpdateService(
            checker: checker,
            defaults: defaults,
            currentVersion: AppVersion("1.0.0"),
            throttle: 0,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: true)
        #expect(service.state == .available(release(tag: "v1.1.0")))

        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .available(release(tag: "v1.1.0")))
    }

    @Test func backgroundCheckThrottled() async {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        defaults.set(now.addingTimeInterval(-60), forKey: "UpdateService.lastCheck")
        let service = UpdateService(
            checker: ExplodingChecker(),
            defaults: defaults,
            currentVersion: AppVersion("1.0.0"),
            throttle: 7200,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .idle)
    }

    @Test func userInitiatedIgnoresThrottle() async {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        defaults.set(now.addingTimeInterval(-60), forKey: "UpdateService.lastCheck")
        let service = UpdateService(
            checker: StubChecker(result: .success(release(tag: "v2.0.0"))),
            defaults: defaults,
            currentVersion: AppVersion("1.0.0"),
            throttle: 7200,
            now: { now }
        )
        await service.checkForUpdates(userInitiated: true)
        #expect(service.state == .available(release(tag: "v2.0.0")))
    }

    @Test func skippedVersionSuppressedInBackgroundButShownWhenManual() async {
        let defaults = freshDefaults()
        let service = UpdateService(
            checker: StubChecker(result: .success(release(tag: "v1.1.0"))),
            defaults: defaults,
            currentVersion: AppVersion("1.0.0")
        )
        service.skip(release(tag: "v1.1.0"))
        #expect(service.state == .idle)

        await service.checkForUpdates(userInitiated: false)
        #expect(service.state == .idle)

        await service.checkForUpdates(userInitiated: true)
        #expect(service.state == .available(release(tag: "v1.1.0")))
    }

    @Test func userInitiatedFailureSurfacesButBackgroundStaysIdle() async {
        let failing = UpdateService(
            checker: StubChecker(result: .failure(UpdateError.badResponse(500))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await failing.checkForUpdates(userInitiated: true)
        if case .failed = failing.state {} else { Issue.record("expected .failed, got \(failing.state)") }

        let silent = UpdateService(
            checker: StubChecker(result: .failure(UpdateError.badResponse(500))),
            defaults: freshDefaults(),
            currentVersion: AppVersion("1.0.0")
        )
        await silent.checkForUpdates(userInitiated: false)
        #expect(silent.state == .idle)
    }
}
