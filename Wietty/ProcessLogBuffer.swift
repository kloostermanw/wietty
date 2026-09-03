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
    /// The absolute sequence number of `lines.first`. Older lines are only ever
    /// appended and trimmed from the front (the open last line is overwritten in
    /// place, which does not change any line's index), so `lines[i]` has the stable
    /// id `firstLineNumber + i`: a value that does not change when the buffer trims.
    /// A view keys its rows by this instead of by array index, so reaching the
    /// line cap and dropping the oldest lines no longer shifts every id and
    /// forces SwiftUI to re-diff and re-lay out the whole list on each append.
    private(set) var firstLineNumber = 0
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
        // Normalize CRLF to a bare newline before the character loop. A PTY in
        // cooked mode (ONLCR) ends every line with `\r\n`, and Swift coalesces
        // `\r\n` into a single `Character` (one grapheme, scalars 13 10) that
        // matches neither the `\r` nor the `\n` branch below. Without this it
        // would fall through as a literal character and no line would ever
        // break, collapsing all output onto one runaway line. A lone `\r` (a
        // progress bar) is left for the loop to handle as an in-place overwrite.
        let cleaned = stripANSI(chunk).replacingOccurrences(of: "\r\n", with: "\n")
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
        if lines.count > limit {
            let trimmed = lines.count - limit
            lines.removeFirst(trimmed)
            firstLineNumber += trimmed
        }
    }

    mutating func clear() {
        lines.removeAll()
        firstLineNumber = 0
        hasOpenLine = false
        openColumn = 0
    }

    /// The buffered lines paired with a position-independent identity, as a
    /// lightweight collection that a `ForEach` can key by. Constructing it copies
    /// only the array header (the strings are shared copy-on-write, not duplicated)
    /// and each `LogLine` is materialised lazily on subscript, so iterating it does
    /// not allocate a parallel array of the whole buffer on every redraw.
    var identifiedLines: IdentifiedLines {
        IdentifiedLines(lines: lines, firstLineNumber: firstLineNumber)
    }

    /// Caps a line at `lineLimit` characters, keeping the most recent tail.
    private func clampedTail(_ characters: [Character]) -> String {
        guard characters.count > lineLimit else { return String(characters) }
        return String(characters.suffix(lineLimit))
    }
}

/// One buffered line with a stable, position-independent identity. The `id` is
/// the line's absolute sequence number, so it survives the buffer trimming older
/// lines away underneath it.
struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// A random-access snapshot of `ProcessLogBuffer.lines` that pairs each line with
/// its stable id without copying the strings. Rows are built on demand, so a
/// `ForEach` over it costs no per-redraw allocation of the whole buffer.
///
/// Its only producer is `ProcessLogBuffer.identifiedLines`, so the fields stay
/// `private` and the initializer `fileprivate`: nothing outside this file can
/// re-expose the buffer's `private(set)` array or build an instance whose
/// `firstLineNumber` disagrees with the lines it was taken from.
struct IdentifiedLines: RandomAccessCollection {
    private let lines: [String]
    private let firstLineNumber: Int

    fileprivate init(lines: [String], firstLineNumber: Int) {
        self.lines = lines
        self.firstLineNumber = firstLineNumber
    }

    var startIndex: Int { 0 }
    var endIndex: Int { lines.count }

    subscript(position: Int) -> LogLine {
        LogLine(id: firstLineNumber + position, text: lines[position])
    }
}
