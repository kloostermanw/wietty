import Foundation

/// Reads one terminal's program status off its output, as the relay hands it over:
/// answers the support query on the spot and reports everything else.
///
/// The answer cannot wait for the main actor, and it cannot come from libghostty,
/// which does not know the sequence. A program asks with `OSC 7501 ; ?` and puts a
/// device attributes request (`CSI c`) right behind it, so that every terminal
/// answers something; whichever reply comes back first decides. libghostty answers
/// the device attributes request as soon as it has read the chunk. So the reply has
/// to be written while the chunk is still in the relay's hands, before it is
/// forwarded to the helper, which is why `reply` is called synchronously from
/// `ingest`. It goes through `RawPTY.write`'s serial queue, the same queue
/// libghostty's own replies reach the master through, so it is queued first by
/// construction rather than by luck.
///
/// One per terminal, fed in stream order from that terminal's read queue and from
/// nowhere else, which is the only reason the unguarded scanner is safe.
final class ProgramStatusTap: @unchecked Sendable {
    /// `OSC 7501 ; ? ST`, the fixed reply section 7 requires. Nothing else is ever
    /// written back: section 8 forbids echoing anything a program reported.
    static let answer = Array("\u{1B}]7501;?\u{1B}\\".utf8)

    private var scanner = ProgramStatusScanner()
    private let reply: @Sendable ([UInt8]) -> Void
    private let report: @Sendable (ProgramStatusScanner.Event) -> Void

    init(reply: @escaping @Sendable ([UInt8]) -> Void,
         report: @escaping @Sendable (ProgramStatusScanner.Event) -> Void) {
        self.reply = reply
        self.report = report
    }

    func ingest(_ bytes: [UInt8]) {
        for event in scanner.scan(bytes) {
            if event == .query { reply(Self.answer) } else { report(event) }
        }
    }
}
