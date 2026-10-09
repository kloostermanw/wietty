import Foundation

/// Finds the Program Status Protocol's sequences in a terminal's raw output, and the
/// two other sequences that decide how long its records live.
///
/// This exists because libghostty does not report `OSC 7501`: the pinned build does
/// not parse it, and upstream Ghostty's own app runtime ignores it too, so a newer
/// build would not help either. Wietty owns the byte stream (see
/// `docs/terminal.md`), so it reads the sequences there, the way `OSCStringTracker`
/// reads bells.
///
/// A sequence can be split across two writes, so the state persists between calls.
/// One scanner per terminal, fed in stream order. Cheap on purpose, because it sees
/// every byte a terminal prints: one switch per byte, and a buffer only while inside
/// an `OSC 7501` or `OSC 133`.
struct ProgramStatusScanner {
    enum Event: Equatable, Sendable {
        /// `OSC 7501 ; ?`, which a supporting terminal must answer (section 7).
        case query
        case report(ProgramStatusReport)
        /// `OSC 133 ; A`, a new shell prompt, which ends `working` and `blocked`
        /// records (section 5).
        case promptStart
        /// `RIS` (`ESC c`), which removes every record (section 4).
        case fullReset
    }

    private enum State {
        case ground
        case escape
        case osc
        /// Inside an OSC and saw ESC: `\` ends it, anything else abandons it.
        case oscEscape
    }

    /// Which OSC is being read, decided by its number.
    private enum Target {
        case number
        case status
        case prompt
        case other
    }

    /// Section 9 caps the whole sequence, `OSC` through `ST`, at 4096 bytes.
    private static let sequenceLimit = 4096
    /// `ESC ]` plus `7501;`.
    private static let statusIntroducer = 7
    /// The most body a sequence can carry and still fit, with the one byte
    /// terminator. The two byte one is checked when it arrives.
    private static let bodyLimit = sequenceLimit - statusIntroducer - 1
    /// Enough digits to tell 7501 from 75010; anything longer is some other OSC.
    private static let numberLimit = 5

    private var state = State.ground
    private var target = Target.number
    private var number: [UInt8] = []
    private var body: [UInt8] = []
    private var overflowed = false

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let can: UInt8 = 0x18
    private static let sub: UInt8 = 0x1A

    mutating func scan(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        for byte in bytes { consume(byte, into: &events) }
        return events
    }

    private mutating func consume(_ byte: UInt8, into events: inout [Event]) {
        switch state {
        case .ground:
            if byte == Self.esc { state = .escape }
        case .escape:
            escape(byte, into: &events)
        case .osc:
            switch byte {
            case Self.bel:
                finish(terminator: 1, into: &events)
            case Self.esc:
                state = .oscEscape
            case Self.can, Self.sub:
                state = .ground
            default:
                collect(byte)
            }
        case .oscEscape:
            if byte == UInt8(ascii: "\\") {
                finish(terminator: 2, into: &events)
            } else {
                // Not a string terminator, so the OSC was never finished and is
                // dropped. The ESC still started something, and this byte is what
                // follows it: `ESC ]` begins the next OSC, `ESC c` is a reset.
                state = .escape
                escape(byte, into: &events)
            }
        }
    }

    private mutating func escape(_ byte: UInt8, into events: inout [Event]) {
        switch byte {
        case UInt8(ascii: "]"):
            state = .osc
            target = .number
            number.removeAll(keepingCapacity: true)
            body.removeAll(keepingCapacity: true)
            overflowed = false
        case UInt8(ascii: "c"):
            events.append(.fullReset)
            state = .ground
        case Self.esc:
            state = .escape
        default:
            state = .ground
        }
    }

    private mutating func collect(_ byte: UInt8) {
        switch target {
        case .number:
            if byte == UInt8(ascii: ";") {
                switch number {
                case Array("7501".utf8): target = .status
                case Array("133".utf8): target = .prompt
                default: target = .other
                }
            } else if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte), number.count < Self.numberLimit {
                number.append(byte)
            } else {
                target = .other
            }
        case .status:
            if body.count < Self.bodyLimit { body.append(byte) } else { overflowed = true }
        case .prompt:
            // `A` and whatever follows it are all that decide a prompt start.
            if body.count < 2 { body.append(byte) }
        case .other:
            break
        }
    }

    private mutating func finish(terminator: Int, into events: inout [Event]) {
        state = .ground
        switch target {
        case .status:
            guard !overflowed,
                  Self.statusIntroducer + body.count + terminator <= Self.sequenceLimit else { return }
            if body == [UInt8(ascii: "?")] {
                events.append(.query)
            } else if let report = ProgramStatusReport.parse(String(decoding: body, as: UTF8.self)) {
                events.append(.report(report))
            }
        case .prompt:
            if body.first == UInt8(ascii: "A"), body.count == 1 || body[1] == UInt8(ascii: ";") {
                events.append(.promptStart)
            }
        case .number, .other:
            break
        }
    }
}
