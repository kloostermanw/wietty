import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The filter that takes a surface's answers to `CSI 18 t` out of the input a remote
/// pane sends to the other Mac: exactly one answer per query, every other byte unchanged
/// and in order, however the reads split it.
@Suite struct SizeAnswerFilterTests {
    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private static let answer = bytes("\u{1B}[8;30;100t")
    private static let size = TerminalSize(cols: 100, rows: 30)

    /// Feeds `reads` one after the other and returns what passed and what was answered.
    private func run(_ scanner: inout SizeAnswerScanner, _ reads: [[UInt8]]) -> ([UInt8], [TerminalSize]) {
        var passed: [UInt8] = []
        var answers: [TerminalSize] = []
        for read in reads {
            let result = scanner.scan(read)
            passed += result.passed
            answers += result.answers
        }
        return (passed, answers)
    }

    @Test func anAnswerAloneIsTakenOut() {
        var scanner = SizeAnswerScanner()
        scanner.queried()
        let (passed, answers) = run(&scanner, [Self.answer])
        #expect(passed.isEmpty)
        #expect(answers == [Self.size])
        #expect(scanner.outstanding == 0)
        #expect(scanner.held.isEmpty)
    }

    @Test func keysBeforeAndAfterInTheSameReadPassUnchanged() {
        var scanner = SizeAnswerScanner()
        scanner.queried()
        let before = Self.bytes("ab\u{1B}[A\u{1B}")
        let after = Self.bytes("\u{1B}[8;3Ax\u{1B}")
        let (passed, answers) = run(&scanner, [before + Self.answer + after, Self.bytes("q")])
        #expect(passed == before + after + Self.bytes("q"))
        #expect(answers == [Self.size])
    }

    @Test func anAnswerSplitAtEveryPositionIsTakenOut() {
        let stream = Self.bytes("k1") + Self.answer + Self.bytes("k2")
        for first in 0...stream.count {
            for second in first...stream.count {
                var scanner = SizeAnswerScanner()
                scanner.queried()
                let reads = [Array(stream[..<first]), Array(stream[first..<second]), Array(stream[second...])]
                let (passed, answers) = run(&scanner, reads)
                #expect(passed == Self.bytes("k1k2"), "split at \(first), \(second)")
                #expect(answers == [Self.size])
                #expect(scanner.held.count <= SizeAnswerScanner.maxHeld)
            }
        }
    }

    @Test func nearMissesPassUnchanged() {
        for text in ["\u{1B}[8;3A", "\u{1B}", "\u{1B}[8~", "\u{1B}[8;;5t", "\u{1B}[8;5;t", "\u{1B}[9;5;5t",
                     "\u{1B}[8;5;5u", "\u{1B}\u{1B}[8;5", "\u{1B}[8;12345678901;5t"] {
            var scanner = SizeAnswerScanner()
            scanner.queried()
            // The next read disproves any prefix still held.
            let (passed, answers) = run(&scanner, [Self.bytes(text), Self.bytes("z")])
            #expect(passed == Self.bytes(text + "z"), "\(text.debugDescription)")
            #expect(answers.isEmpty)
            #expect(scanner.outstanding == 1)
        }
    }

    @Test func digitsOfEveryLengthUpToTenAreAnAnswer() {
        for digits in 1...SizeAnswerScanner.maxDigits {
            let rows = String(repeating: "7", count: digits)
            let cols = String(repeating: "3", count: digits)
            var scanner = SizeAnswerScanner()
            scanner.queried()
            let (passed, answers) = run(&scanner, [Self.bytes("\u{1B}[8;\(rows);\(cols)t")])
            #expect(passed.isEmpty)
            #expect(answers == [TerminalSize(cols: Int(cols)!, rows: Int(rows)!)])
        }
    }

    @Test func withNoQueryOutstandingNothingIsTakenOutOrHeld() {
        var scanner = SizeAnswerScanner()
        let (passed, answers) = run(&scanner, [Self.answer, Array(Self.answer.prefix(5))])
        #expect(passed == Self.answer + Self.answer.prefix(5))
        #expect(answers.isEmpty)
        #expect(scanner.held.isEmpty)
    }

    @Test func oneAnswerPerQueryAndTheNextLookAlikePasses() {
        var scanner = SizeAnswerScanner()
        scanner.queried()
        let (passed, answers) = run(&scanner, [Self.answer + Self.answer])
        #expect(passed == Self.answer)
        #expect(answers == [Self.size])
    }

    @Test func aWithdrawnQueryReleasesWhatWasHeld() {
        var scanner = SizeAnswerScanner()
        scanner.queried()
        let (passed, _) = run(&scanner, [Self.bytes("a\u{1B}[8;")])
        #expect(passed == Self.bytes("a"))
        #expect(scanner.withdrawn() == Self.bytes("\u{1B}[8;"))
        #expect(scanner.outstanding == 0)
        let (later, _) = run(&scanner, [Self.answer])
        #expect(later == Self.answer)
    }

    @Test func theSharedFilterReportsEachAnswer() {
        let seen = Seen()
        let filter = SizeAnswerFilter { seen.add($0) }
        filter.queried()
        #expect(filter.filter(Self.bytes("x") + Self.answer) == Self.bytes("x"))
        #expect(seen.all == [Self.size])
        #expect(filter.outstanding == 0)
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [TerminalSize] = []
        var all: [TerminalSize] { lock.withLock { list } }
        func add(_ size: TerminalSize) { lock.withLock { list.append(size) } }
    }
}
