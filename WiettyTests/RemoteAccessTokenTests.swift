import Testing
import Foundation
@testable import Wietty

@Suite struct RemoteAccessTokenTests {
    private func store() -> RemoteAccessToken {
        RemoteAccessToken(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func generatesAndPersistsAStableToken() {
        let token = store()
        let first = token.value
        #expect(!first.isEmpty)
        #expect(token.value == first)   // stable across reads
    }

    @Test func persistsTheTokenAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = RemoteAccessToken(defaults: defaults).value
        // A fresh instance over the same defaults reads the same persisted value.
        #expect(RemoteAccessToken(defaults: defaults).value == first)
        #expect(first.count == 32)   // 16 random bytes as lowercase hex
    }

    @Test func regenerateChangesTheToken() {
        let token = store()
        let old = token.value
        let new = token.regenerate()
        #expect(new != old)
        #expect(token.value == new)
    }

    @Test func matchesOnlyTheCurrentToken() {
        let token = store()
        #expect(token.matches(token.value))
        #expect(!token.matches("wrong"))
        #expect(!token.matches(nil))
    }
}
