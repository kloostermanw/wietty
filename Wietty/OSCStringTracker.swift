import Foundation

/// Tracks whether a byte stream is currently inside an OSC, DCS, APC, PM, or SOS
/// string, so a 0x07 can be told apart from a bell.
///
/// 0x07 is BEL, but it is also the terminator of an OSC string. Shells with
/// shell integration emit `ESC ] 133 ; A BEL` on every prompt and `ESC ] 0 ;
/// title BEL` on every command, so counting every 0x07 as a bell would ring it
/// several times per command. A sequence can be split across two writes, so the
/// state has to persist between calls.
struct OSCStringTracker {
    private enum State {
        case ground
        case escape        // saw ESC, waiting to see what follows
        case string        // inside OSC/DCS/APC/PM/SOS
        case stringEscape  // inside a string and saw ESC, maybe ST
    }
    private var state: State = .ground

    /// Feeds bytes and returns the number of genuine bells among them.
    mutating func bells(in bytes: [UInt8]) -> Int {
        var count = 0
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
                else if byte == 0x07 { count += 1 }
            case .escape:
                // OSC ']', DCS 'P', SOS 'X', PM '^', APC '_' all open a string.
                if byte == 0x5D || byte == 0x50 || byte == 0x58 || byte == 0x5E || byte == 0x5F {
                    state = .string
                } else if byte == 0x1B {
                    state = .escape
                } else if byte == 0x07 {
                    // A BEL arriving mid-sequence executes immediately rather
                    // than being swallowed by the abandoned escape sequence.
                    count += 1
                    state = .ground
                } else {
                    state = .ground
                }
            case .string:
                if byte == 0x07 { state = .ground }          // BEL terminates, not a bell
                else if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                if byte == 0x5C { state = .ground }          // ESC \ is ST
                else if byte == 0x1B { state = .stringEscape }
                else if byte == 0x07 {
                    // The ESC here was not ST, so the string is still open; the
                    // BEL terminates it just as in the plain .string case, not
                    // a bell.
                    state = .ground
                } else {
                    state = .string
                }
            }
        }
        return count
    }
}
