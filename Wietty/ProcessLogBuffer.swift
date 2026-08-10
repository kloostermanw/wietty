import Foundation

/// Removes ANSI/VT escape sequences so raw PTY output renders as plain text.
/// Handles CSI sequences (ESC [ ... final-byte) and single-char ESC sequences.
func stripANSI(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    var iterator = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = nil
    func next() -> Unicode.Scalar? {
        if let p = pending { pending = nil; return p }
        return iterator.next()
    }
    while let scalar = next() {
        guard scalar == "\u{1B}" else { result.unicodeScalars.append(scalar); continue }
        guard let after = next() else { break }
        if after == "[" {
            // CSI: consume until a final byte in the range @-~ (0x40...0x7E).
            while let c = next() {
                if (0x40...0x7E).contains(c.value) { break }
            }
        }
        // Any other ESC x is dropped (both the ESC and the following scalar).
    }
    return result
}

/// A capped, line-oriented buffer of process output. Newest lines are kept when
/// the line count exceeds `limit`. A chunk without a trailing newline leaves an
/// open last line that the next chunk appends to.
struct ProcessLogBuffer: Equatable {
    private(set) var lines: [String] = []
    private let limit: Int
    private var hasOpenLine = false

    init(limit: Int = 5000) {
        self.limit = max(1, limit)
    }

    mutating func append(_ chunk: String) {
        let cleaned = stripANSI(chunk).replacingOccurrences(of: "\r\n", with: "\n")
        guard !cleaned.isEmpty else { return }
        let endsWithNewline = cleaned.hasSuffix("\n")
        let pieces = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var incoming = pieces
        if endsWithNewline, let last = incoming.last, last.isEmpty { incoming.removeLast() }

        for (offset, piece) in incoming.enumerated() {
            if offset == 0, hasOpenLine, !lines.isEmpty {
                lines[lines.count - 1] += piece
            } else {
                lines.append(piece)
            }
        }
        hasOpenLine = !endsWithNewline
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    mutating func clear() {
        lines.removeAll()
        hasOpenLine = false
    }
}
