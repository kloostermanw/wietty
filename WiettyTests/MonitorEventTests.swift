import Testing
import Foundation
@testable import Wietty

@Suite struct MonitorEventTests {
    @Test func decodesTitle() {
        let e = MonitorEvent.decode(line: #"{"type":"title","session_id":"s1","name":"build stuff"}"#)
        #expect(e == .title(sessionId: "s1", name: "build stuff"))
    }

    @Test func decodesBell() {
        let e = MonitorEvent.decode(line: #"{"type":"bell","session_id":"s2"}"#)
        #expect(e == .bell(sessionId: "s2"))
    }

    @Test func decodesJob() {
        let e = MonitorEvent.decode(line: #"{"type":"job","session_id":"s3","job_name":"node"}"#)
        #expect(e == .job(sessionId: "s3", jobName: "node"))
    }

    @Test func decodesJobWithNullNameAsEmpty() {
        // The daemon coerces None -> "", but be defensive about JSON null too.
        let e = MonitorEvent.decode(line: #"{"type":"job","session_id":"s3","job_name":null}"#)
        #expect(e == .job(sessionId: "s3", jobName: ""))
    }

    @Test func decodesTerminated() {
        let e = MonitorEvent.decode(line: #"{"type":"terminated","session_id":"s4"}"#)
        #expect(e == .terminated(sessionId: "s4"))
    }

    @Test func returnsNilForMalformedLine() {
        #expect(MonitorEvent.decode(line: "not json") == nil)
        #expect(MonitorEvent.decode(line: #"{"type":"title","session_id":"s"}"#) == nil) // missing name
        #expect(MonitorEvent.decode(line: #"{"type":"unknown","session_id":"s"}"#) == nil)
        #expect(MonitorEvent.decode(line: #"{"session_id":"s"}"#) == nil) // missing type
    }
}
