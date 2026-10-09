import Testing
import Foundation
@testable import Wietty

/// Finding the Program Status Protocol's sequences in a terminal's raw output.
@Suite struct ProgramStatusScannerTests {
    private func scan(_ text: String) -> [ProgramStatusScanner.Event] {
        var scanner = ProgramStatusScanner()
        return scanner.scan(Array(text.utf8))
    }

    private let working = ProgramStatusReport.set(id: nil, ProgramStatusRecord(state: .working))
    private let done = ProgramStatusReport.set(id: nil, ProgramStatusRecord(state: .done))

    // MARK: - The query

    @Test func theQueryIsFoundWithEitherTerminator() {
        #expect(scan("\u{1B}]7501;?\u{1B}\\") == [.query])
        #expect(scan("\u{1B}]7501;?\u{07}") == [.query])
    }

    @Test func aQueryWithAnythingAfterTheQuestionMarkIsNotTheQuery() {
        #expect(scan("\u{1B}]7501;?x\u{07}") == [])
    }

    // MARK: - Reports

    @Test func aReportIsFoundWithEitherTerminator() {
        #expect(scan("\u{1B}]7501;state=working\u{1B}\\") == [.report(working)])
        #expect(scan("\u{1B}]7501;state=done\u{07}") == [.report(done)])
    }

    @Test func surroundingOutputIsIgnored() {
        #expect(scan("building…\r\n\u{1B}[1;32mok\u{1B}[0m \u{1B}]7501;state=done\u{07} next") == [.report(done)])
    }

    @Test func aReportTheParserRejectsProducesNothing() {
        #expect(scan("\u{1B}]7501;state=paused\u{07}") == [])
    }

    @Test func otherOscNumbersAreIgnored() {
        // A title, a longer number that starts with 7501, a shorter one it starts
        // with, and iTerm2's notification.
        let text = "\u{1B}]0;state=done\u{07}\u{1B}]75010;state=done\u{07}"
            + "\u{1B}]750;state=done\u{07}\u{1B}]9;state=done\u{07}\u{1B}]7501\u{07}"
        #expect(scan(text) == [])
    }

    @Test func eventsComeOutInStreamOrder() {
        let text = "\u{1B}]7501;?\u{1B}\\\u{1B}]7501;state=working\u{1B}\\\u{1B}]133;A\u{07}\u{1B}c"
        #expect(scan(text) == [.query, .report(working), .promptStart, .fullReset])
    }

    /// A write can end anywhere, including between the ESC and the `\` of a
    /// terminator, so every split of one stream has to find the same events.
    @Test func everySplitAcrossTwoChunksFindsTheSameEvents() {
        let bytes = Array("x\u{1B}]7501;?\u{1B}\\\u{1B}]7501;state=done\u{1B}\\\u{1B}]133;A;redraw=0\u{07}\u{1B}cy".utf8)
        let whole: [ProgramStatusScanner.Event] = [.query, .report(done), .promptStart, .fullReset]
        for split in 0...bytes.count {
            var scanner = ProgramStatusScanner()
            let events = scanner.scan(Array(bytes[..<split])) + scanner.scan(Array(bytes[split...]))
            #expect(events == whole, "split at \(split)")
        }
    }

    // MARK: - The size limit

    /// `ESC ] 7501 ;` is 7 bytes and `ESC \` is 2, so a 4087 byte body makes the
    /// whole sequence exactly 4096. The padding is an unknown key, which a report
    /// may carry and the parser ignores.
    private func report(bodyLength: Int) -> String {
        let head = "state=done:x="
        return "\u{1B}]7501;" + head + String(repeating: "A", count: bodyLength - head.count) + "\u{1B}\\"
    }

    @Test func aSequenceOfExactlyTheLimitIsKept() {
        #expect(report(bodyLength: 4087).utf8.count == 4096)
        #expect(scan(report(bodyLength: 4087)) == [.report(done)])
    }

    @Test func aSequenceOneBytePastTheLimitIsDiscarded() {
        #expect(scan(report(bodyLength: 4088)) == [])
    }

    @Test func aDiscardedSequenceDoesNotSwallowTheNextOne() {
        let huge = "\u{1B}]7501;state=done:x=" + String(repeating: "A", count: 100_000) + "\u{07}"
        #expect(scan(huge + "\u{1B}]7501;state=working\u{07}") == [.report(working)])
    }

    // MARK: - Unterminated sequences

    @Test func anEscapeThatIsNotStringTerminatorAbandonsTheReport() {
        #expect(scan("\u{1B}]7501;state=done\u{1B}[0m") == [])
    }

    @Test func aNewOscStartedMidReportIsReadOnItsOwn() {
        #expect(scan("\u{1B}]7501;state=working\u{1B}]7501;state=done\u{07}") == [.report(done)])
    }

    @Test func cancelAbandonsTheReport() {
        #expect(scan("\u{1B}]7501;state=done\u{18}\u{07}") == [])
        #expect(scan("\u{1B}]7501;state=done\u{1A}\u{07}") == [])
    }

    // MARK: - Shell prompts and resets

    @Test func aPromptStartIsFound() {
        #expect(scan("\u{1B}]133;A\u{07}") == [.promptStart])
        #expect(scan("\u{1B}]133;A;redraw=0\u{1B}\\") == [.promptStart])
    }

    @Test func otherSemanticPromptMarksAreNotAPromptStart() {
        #expect(scan("\u{1B}]133;B\u{07}\u{1B}]133;C\u{07}\u{1B}]133;D;0\u{07}\u{1B}]133;AB\u{07}") == [])
    }

    @Test func aFullResetIsFound() {
        #expect(scan("\u{1B}c") == [.fullReset])
    }

    @Test func primaryDeviceAttributesIsNotAReset() {
        // `CSI c` ends in the same letter as RIS.
        #expect(scan("\u{1B}[c\u{1B}[0c") == [])
    }
}
