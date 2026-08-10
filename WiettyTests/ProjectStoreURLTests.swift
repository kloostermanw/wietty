import Foundation
import Testing
@testable import Wietty

@Suite @MainActor struct ProjectStoreURLTests {
    @Test func issueURLWithValidArguments() {
        let url = ProjectStore.issueURL(owner: "acme", repo: "widget", issue: 42)
        #expect(url == URL(string: "https://github.com/acme/widget/issues/42"))
    }

    @Test func prURLWithValidArguments() {
        let url = ProjectStore.prURL(owner: "acme", repo: "widget", pr: 7)
        #expect(url == URL(string: "https://github.com/acme/widget/pull/7"))
    }

    @Test func issueURLWithNilOwner() {
        let url = ProjectStore.issueURL(owner: nil, repo: "widget", issue: 42)
        #expect(url == nil)
    }

    @Test func issueURLWithNilRepo() {
        let url = ProjectStore.issueURL(owner: "acme", repo: nil, issue: 42)
        #expect(url == nil)
    }

    @Test func issueURLWithNilIssue() {
        let url = ProjectStore.issueURL(owner: "acme", repo: "widget", issue: nil)
        #expect(url == nil)
    }

    @Test func prURLWithNilOwner() {
        let url = ProjectStore.prURL(owner: nil, repo: "widget", pr: 7)
        #expect(url == nil)
    }

    @Test func prURLWithNilRepo() {
        let url = ProjectStore.prURL(owner: "acme", repo: nil, pr: 7)
        #expect(url == nil)
    }

    @Test func prURLWithNilPR() {
        let url = ProjectStore.prURL(owner: "acme", repo: "widget", pr: nil)
        #expect(url == nil)
    }
}
