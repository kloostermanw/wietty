import Testing
@testable import Wietty

/// Covers `RemoteServer.isAuthorized`, the pure predicate at the heart of the
/// LAN control server's auth boundary (guards 7 HTTP routes + 2 WebSocket
/// upgrades in RemoteServer.swift).
@Suite struct RemoteAuthTests {
    @Test func correctTokenAccepted() {
        #expect(RemoteServer.isAuthorized(token: "abc", expected: "abc") == true)
    }

    @Test func wrongTokenRejected() {
        #expect(RemoteServer.isAuthorized(token: "xyz", expected: "abc") == false)
    }

    @Test func missingTokenRejected() {
        #expect(RemoteServer.isAuthorized(token: nil, expected: "abc") == false)
    }

    @Test func emptyClientTokenRejected() {
        #expect(RemoteServer.isAuthorized(token: "", expected: "abc") == false)
    }

    @Test func emptyExpectedRejectedEvenWithEmptyClientToken() {
        #expect(RemoteServer.isAuthorized(token: "", expected: "") == false)
    }

    @Test func emptyExpectedRejectedEvenWithMissingClientToken() {
        #expect(RemoteServer.isAuthorized(token: nil, expected: "") == false)
    }

    @Test func emptyExpectedRejectedEvenWithAnyClientToken() {
        #expect(RemoteServer.isAuthorized(token: "abc", expected: "") == false)
    }
}
