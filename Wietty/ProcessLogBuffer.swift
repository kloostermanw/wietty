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
/// the line count exceeds `limit`, and each line is itself capped at `lineLimit`
/// characters (keeping the most recent tail) so a no-newline emitter cannot grow
/// one line without bound. A chunk without a trailing newline leaves an open last
/// line that the next chunk continues.
///
/// A bare carriage return (`\r`, without a following newline) is treated the way a
/// terminal treats it: the write cursor returns to column 0 and the following
/// characters overwrite the current line in place. This is what a progress bar
/// (`\rprogress 10%`, `\rprogress 20%`, ...) does, and without it that output
/// concatenates into a single ever-growing line that stalls the log pane.
struct ProcessLogBuffer: Equatable {
    private(set) var lines: [String] = []
    private let limit: Int
    private let lineLimit: Int
    private var hasOpenLine = false
    /// Column the next character overwrites when the last line stays open across
    /// chunks. Persisted so a `\r` at the end of one chunk still governs where the
    /// next chunk starts writing.
    private var openColumn = 0

    init(limit: Int = 5000, lineLimit: Int = 8192) {
        self.limit = max(1, limit)
        self.lineLimit = max(1, lineLimit)
    }

    mutating func append(_ chunk: String) {
        let cleaned = stripANSI(chunk)
        guard !cleaned.isEmpty else { return }

        var completed: [String] = []
        var current: [Character]
        var column: Int
        if hasOpenLine, let open = lines.popLast() {
            current = Array(open)
            column = min(openColumn, current.count)
        } else {
            current = []
            column = 0
        }

        for character in cleaned {
            switch character {
            case "\n":
                completed.append(clampedTail(current))
                current = []
                column = 0
            case "\r":
                // Carriage return: move the cursor to the start of the line so the
                // next characters overwrite it in place.
                column = 0
            default:
                if column < current.count {
                    current[column] = character
                } else {
                    current.append(character)
                }
                column += 1
            }
        }

        lines.append(contentsOf: completed)
        hasOpenLine = !current.isEmpty
        if hasOpenLine {
            lines.append(clampedTail(current))
            openColumn = column
        } else {
            openColumn = 0
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    mutating func clear() {
        lines.removeAll()
        hasOpenLine = false
        openColumn = 0
    }

    /// Caps a line at `lineLimit` characters, keeping the most recent tail.
    private func clampedTail(_ characters: [Character]) -> String {
        guard characters.count > lineLimit else { return String(characters) }
        return String(characters.suffix(lineLimit))
    }
}
