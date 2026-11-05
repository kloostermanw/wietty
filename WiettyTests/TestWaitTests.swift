import Testing
import Foundation
@testable import Wietty

@Suite struct TestWaitRequestTests {
    let pid = UUID()

    private func testId(_ name: String) -> String {
        ManagedProcessID.string(projectId: pid, name: name, isTest: true)
    }

    @Test func parsesOneIdWithTheDefaultTimeout() throws {
        let request = try TestWaitRequest.parse([("id", testId("unit"))])
        #expect(request.ids == [testId("unit")])
        #expect(request.timeoutSeconds == 600)
    }

    @Test func parsesRepeatedIdsInOrderAndDropsDuplicates() throws {
        let request = try TestWaitRequest.parse([
            ("id", testId("b")), ("id", testId("a")), ("id", testId("b")),
        ])
        #expect(request.ids == [testId("b"), testId("a")])
    }

    @Test func parsesAnExplicitTimeout() throws {
        let request = try TestWaitRequest.parse([("id", testId("unit")), ("timeout", "1800")])
        #expect(request.timeoutSeconds == 1800)
    }

    /// Zero is a snapshot: report the current statuses without waiting.
    @Test func acceptsAZeroTimeout() throws {
        let request = try TestWaitRequest.parse([("id", testId("unit")), ("timeout", "0")])
        #expect(request.timeoutSeconds == 0)
    }

    @Test func capsTheTimeoutAtOneHour() throws {
        let request = try TestWaitRequest.parse([("id", testId("unit")), ("timeout", "99999")])
        #expect(request.timeoutSeconds == 3600)
    }

    @Test(arguments: ["-1", "abc", "1.5", ""])
    func rejectsATimeoutThatIsNotANonNegativeInteger(_ raw: String) {
        #expect(throws: TestWaitError.invalidTimeout(raw)) {
            try TestWaitRequest.parse([("id", testId("unit")), ("timeout", raw)])
        }
    }

    @Test func rejectsARequestWithoutAnId() {
        #expect(throws: TestWaitError.missingId) {
            try TestWaitRequest.parse([("timeout", "10")])
        }
    }

    @Test func rejectsAMalformedId() {
        #expect(throws: TestWaitError.invalidId("nonsense")) {
            try TestWaitRequest.parse([("id", "nonsense")])
        }
    }

    /// A process never finishes the way a test does, so waiting on one is a mistake
    /// rather than an unknown id.
    @Test func rejectsAProcessId() {
        let processId = ManagedProcessID.string(projectId: pid, name: "queue", isTest: false)
        #expect(throws: TestWaitError.notATest(processId)) {
            try TestWaitRequest.parse([("id", processId)])
        }
    }

    @Test func ignoresUnrelatedParameters() throws {
        let request = try TestWaitRequest.parse([("id", testId("unit")), ("verbose", "1")])
        #expect(request.ids == [testId("unit")])
    }

    @Test func everyRequestErrorIsABadRequest() {
        for error in [TestWaitError.missingId, .invalidId("x"), .notATest("x"), .invalidTimeout("x")] {
            #expect(error.httpStatus == 400)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}

@Suite struct TestWaitOutcomeTests {
    @Test func allFinishedIsOK() {
        let outcome = TestWaitOutcome(states: [.finished, .finished], settled: true)
        #expect(outcome == .finished)
        #expect(outcome.httpStatus == 200)
        #expect(outcome.done)
    }

    @Test func anyFailedIsUnprocessable() {
        let outcome = TestWaitOutcome(states: [.finished, .failed(1)], settled: true)
        #expect(outcome == .failed)
        #expect(outcome.httpStatus == 422)
        #expect(outcome.done)
    }

    /// An idle test is settled but never ran, so the wait is over without a verdict.
    @Test func anIdleTestIsAConflictEvenNextToAFailure() {
        let outcome = TestWaitOutcome(states: [.idle, .failed(1)], settled: true)
        #expect(outcome == .notStarted)
        #expect(outcome.httpStatus == 409)
        #expect(!outcome.done)
    }

    @Test func anUnsettledWaitIsATimeoutWhateverTheOtherStatuses() {
        let outcome = TestWaitOutcome(states: [.running, .idle, .failed(1)], settled: false)
        #expect(outcome == .timedOut)
        #expect(outcome.httpStatus == 504)
        #expect(!outcome.done)
    }
}
