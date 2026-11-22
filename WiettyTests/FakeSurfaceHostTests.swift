import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The stand in every later test of this substrate runs against.
@MainActor
@Suite struct FakeSurfaceHostTests {
    /// The one branch of the real host that decides what a read costs, asserted
    /// without a live surface.
    ///
    /// A read of exactly the grid's own row count is the visible screen, and the
    /// cheap read answers it in full. Reading the boundary as `>=` sends it down
    /// the whole screen path, roughly 34 ms of main actor time instead of
    /// 0.14 ms, and nothing else would notice. The read is only the coexistence
    /// check's now, which asks for exactly the grid on every poll.
    @Test func exactlyTheGridIsTheCheapReadAndOnlyMoreReachesScrollback() {
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 28, gridRows: 28) == false)
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 27, gridRows: 28) == false)
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 29, gridRows: 28) == true)
        #expect(GhosttySurfaceHost.readsScrollback(maxLines: 5000, gridRows: 28) == true)
    }

    /// A failure leaves no view behind, which is what `GhosttyService` relies on
    /// when it unwinds a half built terminal.
    @Test func aFailedCreateRegistersNothing() {
        let host = FakeSurfaceHost()
        host.failNextCreate = true
        #expect(throws: SurfaceHostError.surfaceFailed) {
            try host.createSurface(id: "gt:2", command: "/usr/bin/true",
                                   directory: URL(fileURLWithPath: "/tmp"), title: nil)
        }
        #expect(host.created.isEmpty)
        #expect(host.view(id: "gt:2") == nil)
    }
}
