import Testing
@testable import Wietty

@Suite struct ProcessStateTests {
    @Test func dotMapping() {
        #expect(processDot(for: .running) == ProcessDot(fill: .filled, color: .green))
        #expect(processDot(for: .orphaned) == ProcessDot(fill: .filled, color: .green))
        #expect(processDot(for: .finished) == ProcessDot(fill: .open, color: .green))
        #expect(processDot(for: .failed(3)) == ProcessDot(fill: .open, color: .red))
        #expect(processDot(for: .idle) == ProcessDot(fill: .open, color: .gray))
        #expect(processDot(for: .starting) == ProcessDot(fill: .open, color: .gray))
        #expect(processDot(for: .stopping) == ProcessDot(fill: .filled, color: .green))
    }

    @Test func runningMapping() {
        // Live: a process is running while it is up or transitioning.
        #expect(processIsRunning(for: .running))
        #expect(processIsRunning(for: .starting))
        #expect(processIsRunning(for: .stopping))
        #expect(processIsRunning(for: .orphaned))
        // Not live: never started or already exited.
        #expect(!processIsRunning(for: .idle))
        #expect(!processIsRunning(for: .finished))
        #expect(!processIsRunning(for: .failed(1)))
    }
}
