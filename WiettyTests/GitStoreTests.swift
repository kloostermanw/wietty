import Testing
import Foundation
@testable import Wietty

final class FakeGitInfoProvider: GitInfoProviding, @unchecked Sendable {
    var results: [String: GitInfo] = [:]   // keyed by standardized folder path

    func gitSync(for folder: URL) async -> GitSync? {
        guard let info = results[folder.standardizedFileURL.path] else { return nil }
        return GitSync(
            branch: info.branch, behind: info.behind, ahead: info.ahead, hasUpstream: info.hasUpstream,
            upstreamRef: info.upstreamRef, baseAhead: info.baseAhead, baseBehind: info.baseBehind,
            hasBase: info.hasBase, baseRef: info.baseRef, owner: nil, repo: nil, issueNumber: info.issueNumber
        )
    }

    func pullRequestNumber(for folder: URL, branch: String) async -> Int? {
        results[folder.standardizedFileURL.path]?.prNumber
    }

    func ciChecks(for folder: URL, prNumber: Int) async -> ChecksSummary? {
        results[folder.standardizedFileURL.path]?.checks
    }
}

@Suite @MainActor struct GitStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private func makeTempFolder(named name: String) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = base.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gitInfo(behind: Int, ahead: Int, pr: Int?) -> GitInfo {
        GitInfo(branch: "feature/issue-1", behind: behind, ahead: ahead, hasUpstream: true,
                issueNumber: 1, prNumber: pr, issueURL: nil, prURL: nil)
    }

    @Test func refreshPopulatesGitInfoByProjectId() async {
        let provider = FakeGitInfoProvider()
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(), gitProvider: provider)
        let folder = makeTempFolder(named: "proj")
        store.addProject(url: folder)
        provider.results[folder.standardizedFileURL.path] = gitInfo(behind: 2, ahead: 3, pr: 9)

        await store.refreshAllGitInfo()
        let id = store.projects[0].id
        #expect(store.gitInfo[id]?.behind == 2)
        #expect(store.gitInfo[id]?.ahead == 3)
        #expect(store.gitInfo[id]?.prNumber == 9)
    }

    @Test func refreshWithNilResultClearsEntry() async {
        let provider = FakeGitInfoProvider()
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(), gitProvider: provider)
        let folder = makeTempFolder(named: "proj")
        store.addProject(url: folder)
        let id = store.projects[0].id
        provider.results[folder.standardizedFileURL.path] = gitInfo(behind: 1, ahead: 1, pr: nil)
        await store.refreshAllGitInfo()
        #expect(store.gitInfo[id] != nil)

        provider.results.removeValue(forKey: folder.standardizedFileURL.path)
        await store.refreshAllGitInfo()
        #expect(store.gitInfo[id] == nil)
    }

    @Test func removingProjectClearsGitInfo() async {
        let provider = FakeGitInfoProvider()
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(), gitProvider: provider)
        let folder = makeTempFolder(named: "proj")
        store.addProject(url: folder)
        let project = store.projects[0]
        provider.results[folder.standardizedFileURL.path] = gitInfo(behind: 1, ahead: 1, pr: nil)
        await store.refreshAllGitInfo()
        #expect(store.gitInfo[project.id] != nil)

        store.remove(project)
        #expect(store.gitInfo[project.id] == nil)
    }

    @Test func processVariablesAlwaysExposeWorkspacePathAndName() {
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(), gitProvider: FakeGitInfoProvider())
        let folder = makeTempFolder(named: "myapp")
        store.addProject(url: folder)
        let project = store.projects[0]
        let vars = store.processVariables(for: project.id)
        #expect(vars["WIETTY_WORKSPACE_PATH"] == project.url.path)
        #expect(vars["WIETTY_WORKSPACE_NAME"] == "myapp")
        // No git sync has run, so no git-derived variables are present.
        #expect(vars["WIETTY_BRANCH"] == nil)
        #expect(vars["WIETTY_PR_NUMBER"] == nil)
    }

    @Test func processVariablesExposeGitValuesWhenKnown() async {
        let provider = FakeGitInfoProvider()
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(), gitProvider: provider)
        let folder = makeTempFolder(named: "proj")
        store.addProject(url: folder)
        provider.results[folder.standardizedFileURL.path] = gitInfo(behind: 0, ahead: 0, pr: 42)
        await store.refreshAllGitInfo()

        let id = store.projects[0].id
        let vars = store.processVariables(for: id)
        #expect(vars["WIETTY_BRANCH"] == "feature/issue-1")
        #expect(vars["WIETTY_ISSUE_NUMBER"] == "1")
        #expect(vars["WIETTY_PR_NUMBER"] == "42")
    }

    @Test func refreshHandlesMoreProjectsThanConcurrencyLimit() async {
        let provider = FakeGitInfoProvider()
        let store = ProjectStore(defaults: makeDefaults(), service: FakeTerminalService(), gitProvider: provider)
        for i in 0..<7 {
            let folder = makeTempFolder(named: "p\(i)")
            store.addProject(url: folder)
            provider.results[folder.standardizedFileURL.path] = gitInfo(behind: i, ahead: 0, pr: nil)
        }
        await store.refreshAllGitInfo()
        #expect(store.gitInfo.count == 7)
    }
}
