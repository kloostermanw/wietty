import Foundation
import WiettyCore

/// Takes a terminal's answers to `CSI 18 t` out of a byte stream, and nothing else.
///
/// A remote pane asks its own surface `CSI 18 t` (text area size in characters) while it
/// holds a snapshot, to learn when libghostty has really resized the terminal (the
/// surface's own grid report comes before the terminal behind it takes the size). The
/// surface answers `ESC [ 8 ; <rows> ; <cols> t` as input, which the helper hands the
/// bridge as if the user had typed it. Those answers must never reach the other Mac, and
/// nothing else may be removed or reordered.
///
/// Exactly one answer is removed per query outstanding (`queried()`), in the order the
/// bytes come, and reported with the query it answers (the oldest outstanding: answers
/// come in the order the queries were written). With no query outstanding every byte
/// passes as it comes. With one outstanding, bytes that could still be the start of an
/// answer are held back until a later byte decides: completed, they are the answer and
/// removed; disproved, the first held byte passes and the rest is scanned again, so every
/// byte that is not the answer passes unchanged and in order.
///
/// A query that will not be answered after all (`withdrawn(_:)`: never written, or given
/// up on) takes nothing with it: bytes held back when the last query outstanding goes are
/// kept, and the next `scan` passes them on first, before the bytes it is given. So held
/// bytes wait at most for the next read, and only `scan` (one thread, the helper's
/// reader) ever hands bytes on, which keeps their order.
///
/// Each number has at most `maxDigits` digits (a grid side is at most 10,000), so at most
/// `maxHeld` bytes (`ESC [ 8 ;`, ten digits, `;`, ten digits: 25) are ever held back; an
/// eleventh digit disproves the answer.
struct SizeAnswerScanner {
    static let query: [UInt8] = Array("\u{1B}[18t".utf8)
    static let maxDigits = 10
    static let maxHeld = 4 + maxDigits + 1 + maxDigits

    /// An answer taken out, and the query it answers.
    struct Answer: Equatable, Sendable {
        let query: Int
        let size: TerminalSize
    }

    /// The queries sent whose answer has not been taken out yet, oldest first.
    private(set) var queries: [Int] = []
    private var lastQuery = 0
    /// A proper prefix of an answer, held until the next byte decides.
    private(set) var held: [UInt8] = []
    /// Bytes held back when the last query outstanding went: passed on first by the
    /// next `scan`.
    private(set) var released: [UInt8] = []

    var outstanding: Int { queries.count }

    /// A query is sent (before it is written, so its answer cannot come first). Its
    /// number, for `withdrawn(_:)` and to tell its answer from another's.
    @discardableResult
    mutating func queried() -> Int {
        lastQuery += 1
        queries.append(lastQuery)
        return lastQuery
    }

    /// `query`'s answer will not be taken out: it was never written, or it is given up
    /// on. Nothing for a query answered or withdrawn already. What is held is kept for the
    /// next `scan` to pass on.
    mutating func withdrawn(_ query: Int) {
        queries.removeAll { $0 == query }
        if queries.isEmpty, !held.isEmpty {
            released += held
            held = []
        }
    }

    /// The bytes to pass on, in order, and the answers taken out of them.
    mutating func scan(_ bytes: [UInt8]) -> (passed: [UInt8], answers: [Answer]) {
        var passed = released
        released = []
        var answers: [Answer] = []
        var input = bytes
        var index = 0
        while index < input.count {
            let byte = input[index]
            index += 1
            if held.isEmpty {
                if !queries.isEmpty, byte == 0x1B { held = [byte] } else { passed.append(byte) }
                continue
            }
            held.append(byte)
            switch Self.match(held) {
            case .prefix:
                continue
            case .complete(let size):
                answers.append(Answer(query: queries.removeFirst(), size: size))
                held = []
            case .none:
                // The first held byte is not an answer's start; the rest may hold one.
                passed.append(held[0])
                input = Array(held.dropFirst()) + input[index...]
                index = 0
                held = []
            }
        }
        return (passed, answers)
    }

    enum Match: Equatable {
        case prefix
        case complete(TerminalSize)
        case none
    }

    /// Whether `bytes` (starting with ESC) is a proper prefix of an answer, an answer, or
    /// neither.
    static func match(_ bytes: [UInt8]) -> Match {
        let head: [UInt8] = [0x1B, 0x5B, 0x38, 0x3B]   // ESC [ 8 ;
        for (offset, byte) in bytes.prefix(head.count).enumerated() where byte != head[offset] {
            return .none
        }
        guard bytes.count > head.count else { return .prefix }
        var index = head.count
        func number() -> (value: Int, digits: Int)? {
            var value = 0
            var digits = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                digits += 1
                if digits > maxDigits { return nil }
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            return (value, digits)
        }
        guard let rows = number() else { return .none }
        guard index < bytes.count else { return .prefix }
        guard rows.digits > 0, bytes[index] == 0x3B else { return .none }
        index += 1
        guard let cols = number() else { return .none }
        guard index < bytes.count else { return .prefix }
        guard cols.digits > 0, bytes[index] == 0x74, index == bytes.count - 1 else { return .none }
        return .complete(TerminalSize(cols: cols.value, rows: rows.value))
    }
}

/// `SizeAnswerScanner` for one surface's input, shared by every link of its pane: the
/// answer comes back on the helper's stream whichever link the bridge has by then, so a
/// query asked through a link that was replaced still has its answer taken out.
/// Thread safe; the scan runs on the bridge's helper thread, the queries are armed and
/// expired from the main actor, and withdrawn on whichever thread stops a link. The lock
/// is never held across a call out.
final class SizeAnswerFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var scanner = SizeAnswerScanner()
    private let onAnswer: @Sendable (SizeAnswerScanner.Answer) -> Void

    /// - Parameter onAnswer: every answer taken out, on the thread that scanned it;
    ///   must return at once.
    init(onAnswer: @escaping @Sendable (SizeAnswerScanner.Answer) -> Void) {
        self.onAnswer = onAnswer
    }

    var outstanding: Int { lock.withLock { scanner.outstanding } }
    /// Whether `query`'s answer is still to be taken out.
    func isOutstanding(_ query: Int) -> Bool { lock.withLock { scanner.queries.contains(query) } }
    /// How many bytes are held back now, also those the next read passes on first. For
    /// tests.
    var heldCount: Int { lock.withLock { scanner.held.count + scanner.released.count } }

    /// Arms the filter for one more answer. The query's number.
    @discardableResult
    func queried() -> Int { lock.withLock { scanner.queried() } }

    /// A query that was never written: its answer will not come. Bytes held back are
    /// passed on by the next read.
    func withdrawn(_ query: Int) { lock.withLock { scanner.withdrawn(query) } }

    /// Gives up on `query`'s answer, if it is still outstanding: the terminal did not
    /// answer in time, or the query was lost on its way (its link replaced between being
    /// taken off the link's queue and being written). Bytes held back are passed on by
    /// the next read. An answer that does come after this is not taken out: it reaches
    /// the other Mac as if typed, which is accepted, since it can no longer be told from
    /// a program's own `CSI 18 t` answer.
    func expire(_ query: Int) { lock.withLock { scanner.withdrawn(query) } }

    /// The bytes to pass on to the other Mac.
    func filter(_ bytes: [UInt8]) -> [UInt8] {
        let (passed, answers) = lock.withLock { scanner.scan(bytes) }
        for answer in answers { onAnswer(answer) }
        return passed
    }
}
