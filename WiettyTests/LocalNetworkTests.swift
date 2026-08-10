import Testing
@testable import Wietty

@Suite struct LocalNetworkTests {
    @Test func primaryIPv4IsNilOrDottedQuad() {
        if let ip = LocalNetwork.primaryIPv4() {
            let parts = ip.split(separator: ".")
            #expect(parts.count == 4)
            #expect(!ip.hasPrefix("127."))   // never loopback
        }
        // On a machine with no active interface this is nil; that is allowed.
    }
}
