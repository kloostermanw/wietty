import Foundation

/// Accumulates raw bytes and yields only complete UTF-8, holding back a
/// trailing incomplete sequence until its continuation bytes arrive.
///
/// The hold-back is bounded by construction: a UTF-8 sequence is at most four
/// bytes, and an invalid lead byte or a bad continuation is replaced with
/// U+FFFD immediately. Without that, one byte of binary output (`cat` on a
/// binary file) would wedge a pane permanently.
struct UTF8Chunker {
    private var pending: [UInt8] = []

    mutating func take(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        var out = ""
        var index = 0
        while index < pending.count {
            let needed = Self.sequenceLength(pending[index])
            if needed == 0 {
                out.unicodeScalars.append("\u{FFFD}")
                index += 1
                continue
            }
            if index + needed > pending.count {
                break   // incomplete tail: wait for the next chunk
            }
            let slice = Array(pending[index..<(index + needed)])
            if let decoded = String(bytes: slice, encoding: .utf8) {
                out += decoded
                index += needed
            } else {
                out.unicodeScalars.append("\u{FFFD}")
                index += 1
                // Skip continuation bytes that were part of the failed sequence
                while index < pending.count && pending[index] >= 0x80 && pending[index] < 0xC0 {
                    index += 1
                }
            }
        }
        pending.removeFirst(index)
        return out
    }

    /// Byte length of the UTF-8 sequence a lead byte introduces, or 0 when the
    /// byte cannot start one.
    private static func sequenceLength(_ byte: UInt8) -> Int {
        switch byte {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 0
        }
    }
}
