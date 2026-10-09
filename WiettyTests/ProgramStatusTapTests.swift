import Testing
import Foundation
@testable import Wietty

/// Lock guarded, because the tap's callbacks are `@Sendable`.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReplies: [[UInt8]] = []
    private var storedEvents: [ProgramStatusScanner.Event] = []
    private var storedOrder: [String] = []
    func reply(_ bytes: [UInt8]) { lock.lock(); storedReplies.append(bytes); storedOrder.append("reply"); lock.unlock() }
    func event(_ event: ProgramStatusScanner.Event) { lock.lock(); storedEvents.append(event); storedOrder.append("event"); lock.unlock() }
    var replies: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return storedReplies }
    var events: [ProgramStatusScanner.Event] { lock.lock(); defer { lock.unlock() }; return storedEvents }
    var order: [String] { lock.lock(); defer { lock.unlock() }; return storedOrder }
}

/// One terminal's program status, read off its output where the relay hands it over.
@Suite struct ProgramStatusTapTests {
    private func tap(_ recorder: Recorder) -> ProgramStatusTap {
        ProgramStatusTap(reply: { recorder.reply($0) }, report: { recorder.event($0) })
    }

    /// The reply has to be written while the relay still holds the chunk: a program
    /// sends the query with a device attributes request right behind it and takes
    /// whichever answer arrives first, so a reply queued after libghostty has seen
    /// that request arrives too late and the program decides there is no support.
    @Test func aQueryIsAnsweredBeforeIngestReturns() {
        let recorder = Recorder()
        tap(recorder).ingest(Array("\u{1B}]7501;?\u{07}".utf8))
        #expect(recorder.replies == [[0x1B, 0x5D, 0x37, 0x35, 0x30, 0x31, 0x3B, 0x3F, 0x1B, 0x5C]])
    }

    @Test func aQueryIsAnsweredOnlyOnce() {
        let recorder = Recorder()
        let tap = tap(recorder)
        tap.ingest(Array("\u{1B}]7501;?".utf8))
        tap.ingest(Array("\u{1B}\\".utf8))
        #expect(recorder.replies.count == 1)
        #expect(recorder.events.isEmpty)
    }

    @Test func everythingElseIsReportedInStreamOrder() {
        let recorder = Recorder()
        tap(recorder).ingest(Array("\u{1B}]7501;state=done\u{07}\u{1B}]7501;?\u{07}\u{1B}]133;A\u{07}\u{1B}c".utf8))
        #expect(recorder.events == [.report(.set(id: nil, ProgramStatusRecord(state: .done))),
                                    .promptStart, .fullReset])
        #expect(recorder.order == ["event", "reply", "event", "event"])
    }

    @Test func plainOutputProducesNothing() {
        let recorder = Recorder()
        tap(recorder).ingest(Array("hello\u{07}\r\n".utf8))
        #expect(recorder.replies.isEmpty && recorder.events.isEmpty)
    }
}
