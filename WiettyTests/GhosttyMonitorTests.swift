import Testing
import Foundation
@testable import Wietty

/// Where per session events come from on this substrate. Titles and bells are
/// pushed by libghostty; terminations are pushed by the service; jobs are polled
/// and deliberately not here.
@MainActor
@Suite struct GhosttyMonitorTests {
    @Test func aTitleFromTheSurfaceBecomesATitleEvent() {
        let host = FakeSurfaceHost()
        let monitor = GhosttyMonitor(host: host)
        var events: [MonitorEvent] = []
        monitor.start { events.append($0) }
        host.emitTitle("gt:1", "~/repos/wietty")
        #expect(events == [.title(sessionId: "gt:1", name: "~/repos/wietty")])
    }

    /// The bell comes from libghostty's action callback rather than from parsing
    /// the byte stream. `OSCStringTracker` counts only bells and would need OSC 0
    /// and OSC 2 parsing added to serve titles, and the callback is already
    /// correct for both.
    @Test func aBellFromTheSurfaceBecomesABellEvent() {
        let host = FakeSurfaceHost()
        let monitor = GhosttyMonitor(host: host)
        var events: [MonitorEvent] = []
        monitor.start { events.append($0) }
        host.emitBell("gt:2")
        #expect(events == [.bell(sessionId: "gt:2")])
    }

    /// The service owns terminations, because the child exiting is what a
    /// termination is and only the service reaps it. The monitor is the app's one
    /// listener, so it has to be the thing that carries the event.
    @Test func anEmittedTerminationReachesTheListener() {
        let monitor = GhosttyMonitor(host: FakeSurfaceHost())
        var events: [MonitorEvent] = []
        monitor.start { events.append($0) }
        monitor.emit([.terminated(sessionId: "gt:3")])
        #expect(events == [.terminated(sessionId: "gt:3")])
    }

    /// Stopping must be final. A listener left attached after teardown would
    /// deliver into a store the app has stopped using.
    @Test func stoppingDropsTheListener() {
        let host = FakeSurfaceHost()
        let monitor = GhosttyMonitor(host: host)
        var events: [MonitorEvent] = []
        monitor.start { events.append($0) }
        monitor.stop()
        host.emitBell("gt:4")
        monitor.emit([.terminated(sessionId: "gt:4")])
        #expect(events.isEmpty)
    }

    /// Events arriving before anything is listening are dropped rather than
    /// queued. The monitor is started once, in `ContentView.task`, before any
    /// terminal can exist, so a queue would only ever hold events from a
    /// substrate that had already been torn down.
    ///
    /// Asserted by attaching a listener afterwards: if the bell had been queued,
    /// it would arrive here.
    @Test func eventsBeforeStartAreDropped() {
        let host = FakeSurfaceHost()
        let monitor = GhosttyMonitor(host: host)
        host.emitBell("gt:5")
        var events: [MonitorEvent] = []
        monitor.start { events.append($0) }
        #expect(events.isEmpty)
    }
}
