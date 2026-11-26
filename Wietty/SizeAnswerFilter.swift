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
/// bytes come. With no query outstanding every byte passes as it comes. With one
/// outstanding, bytes that could still be the start of an answer are held back until a
/// later byte decides: completed, they are the answer and removed; disproved, the first
/// held byte passes and the rest is scanned again, so every byte that is not the answer
/// passes unchanged and in order. Held bytes wait at most for the next read.
///
/// Each number has at most `maxDigits` digits (a grid side is at most 10,000), so at most
/// `maxHeld` bytes (`ESC [ 8 ;`, ten digits, `;`, ten digits: 25) are ever held back; an
/// eleventh digit disproves the answer.
struct SizeAnswerScanner {
    static let query: [UInt8] = Array("\u{1B}[18t".utf8)
    static let maxDigits = 10
    static let maxHeld = 4 + maxDigits + 1 + maxDigits

    /// Queries sent whose answer has not been taken out yet.
    private(set) var outstanding = 0
    /// A proper prefix of an answer, held until the next byte decides.
    private(set) var held: [UInt8] = []

    /// A query was sent (before it is written, so its answer cannot come first).
    mutating func queried() { outstanding += 1 }

    /// A query that was never written: its answer will not come.
    mutating func withdrawn() -> [UInt8] {
        outstanding = max(0, outstanding - 1)
        guard outstanding == 0 else { return [] }
        defer { held = [] }
        return held
    }

    /// The bytes to pass on, in order, and the answers taken out of them.
    mutating func scan(_ bytes: [UInt8]) -> (passed: [UInt8], answers: [TerminalSize]) {
        var passed: [UInt8] = []
        var answers: [TerminalSize] = []
        var input = bytes
        var index = 0
        while index < input.count {
            let byte = input[index]
            index += 1
            if held.isEmpty {
                if outstanding > 0, byte == 0x1B { held = [byte] } else { passed.append(byte) }
                continue
            }
            held.append(byte)
            switch Self.match(held) {
            case .prefix:
                continue
            case .complete(let size):
                answers.append(size)
                outstanding -= 1
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
/// Thread safe; the scan runs on the bridge's helper thread, the count is armed from the
/// main actor.
final class SizeAnswerFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var scanner = SizeAnswerScanner()
    private let onAnswer: @Sendable (TerminalSize) -> Void

    /// - Parameter onAnswer: every answer taken out, on the thread that scanned it;
    ///   must return at once.
    init(onAnswer: @escaping @Sendable (TerminalSize) -> Void) {
        self.onAnswer = onAnswer
    }

    var outstanding: Int { lock.withLock { scanner.outstanding } }
    /// How many bytes are held back now. For tests.
    var heldCount: Int { lock.withLock { scanner.held.count } }

    func queried() { lock.withLock { scanner.queried() } }

    /// A query that was never written. Returns held bytes to pass on, if that was the
    /// last one outstanding.
    func withdrawn() -> [UInt8] { lock.withLock { scanner.withdrawn() } }

    /// The bytes to pass on to the other Mac.
    func filter(_ bytes: [UInt8]) -> [UInt8] {
        let (passed, answers) = lock.withLock { scanner.scan(bytes) }
        for answer in answers { onAnswer(answer) }
        return passed
    }
}
