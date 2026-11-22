import Foundation

/// What the core knows about one terminal's screen, held in memory and answerable
/// with no window: the server's own terminal.
///
/// A libghostty surface can only say what is on a terminal's screen while that
/// terminal is on screen, in plain text and with no cursor. A model parses the same
/// bytes the surface does and answers for any terminal at any time.
///
/// **A model never answers the program.** The surface replies to terminal queries
/// by writing to the pty, and a second answerer is a wrong answer the moment the
/// two disagree about any state. A conformance must therefore stay silent: bytes
/// go in, and nothing but the reads below comes out.
///
/// `Sendable`, and it has to be: bytes arrive on a terminal's relay queue, a paint
/// is asked for on the hub's delivery queue, and text is read on the main actor.
/// None of the three may wait for a hop to another, so a conformance serialises
/// its own calls.
package protocol TerminalScreenModel: AnyObject, Sendable {
    /// Bytes from the pty, in stream order. Called on the relay's queue.
    func write(_ bytes: [UInt8])

    /// The grid changed. The surface decides the grid and the model follows it.
    func resize(to size: TerminalSize)

    /// VT for painting a client that is attaching now: the visible viewport, with
    /// colours, cursor, modes and the rest, for a terminal that has just reset.
    func paintFrame() -> [UInt8]

    /// The whole terminal as bytes that restore it: screen, scrollback, title, modes,
    /// and the screen that is not active. For surviving a restart, not for painting.
    ///
    /// **Keep this off the per frame and per attach path.** It is megabytes for a
    /// full scrollback and it is taken under the same lock every `write` takes, so
    /// calling it per frame stalls the terminal's own output behind it. Nothing in
    /// the type system stops that, which is why it is said here.
    func snapshot() -> Data

    /// Plain text, most recent lines last, capped at `maxLines` lines. A line the
    /// terminal wrapped is one line, and the blank rows below the last line with
    /// text are not lines. Reaches as far into the scrollback as it has to.
    func text(maxLines: Int) -> String

    /// The grid, as the model holds it.
    var size: TerminalSize { get }
}

extension TerminalScreenModel {
    /// What a viewer is sent to show this terminal as it is now: its grid, then
    /// the VT that paints it.
    ///
    /// The same two messages a viewer has always been painted with, so nothing
    /// about the protocol moves; there are simply colours, modes and a real cursor
    /// inside the second one. The size comes first because a viewer learns its
    /// grid from this and from nothing else.
    ///
    /// The frame paints a terminal that has just been reset, and a viewer being
    /// repainted after a resize is not one, so the payload starts by making it
    /// close enough to one: see `TerminalPaint.reset`.
    package func paintMessages() -> [RemoteMessage] {
        let size = self.size
        let frame = paintFrame()
        guard !frame.isEmpty else { return [] }
        return [.resize(cols: size.cols, rows: size.rows),
                .data(TerminalPaint.reset + String(decoding: frame, as: UTF8.self))]
    }
}

package enum TerminalPaint {
    /// What a paint frame is prefixed with: a soft reset (DECSTR), erase the
    /// screen, home.
    ///
    /// The frame itself erases nothing. It walks the rows and writes what is in
    /// them, so on a viewer that already shows something, whatever a shorter row
    /// leaves uncovered would stay. The soft reset is there for the margins and
    /// origin mode: with either still set from before, the erase and every row
    /// after it would land inside the old scrolling region.
    ///
    /// Deliberately not a hard reset, which would also throw away the scrollback
    /// a viewer has built up from the stream, on every notch of a window drag.
    /// And deliberately without leaving the alternate screen: a viewer that is
    /// on it is there because the terminal is, the frame puts it there again
    /// anyway, and leaving first would aim the erase at the primary screen the
    /// viewer is keeping underneath.
    package static let reset = "\u{1B}[!p\u{1B}[2J\u{1B}[H"
}

/// How much history a terminal's model keeps.
///
/// One place, because the number is a memory decision: a retained row costs
/// roughly 1 KiB at 120 columns, so this is about 10 MiB for a terminal that has
/// filled its scrollback, and thirty such terminals are about 300 MiB.
package enum TerminalScrollback {
    /// Lines of history per terminal. The library prunes a page at a time, so a
    /// full scrollback holds somewhat fewer rows than this, never more.
    package static let lines = 10_000
}

/// A `TerminalScreenModel` backed by libghostty-vt.
///
/// One lock per model, held for the whole of each call. libghostty-vt's terminal
/// is not reentrant and nothing in it checks, so a read that overlapped a write
/// would walk pages the parser is rewriting. The lock is the same shape
/// `SharedTerminalState` uses, for the same reason: the callers are on three
/// different queues and none of them can hop.
///
/// The lock is only cheap because what is called often is cheap. A write parses at
/// hundreds of megabytes a second and a paint frame formats one viewport in
/// hundredths of a millisecond. `snapshot()` is the exception, which is why its
/// declaration says where it must not be called from.
package final class GhosttyVtScreenModel: TerminalScreenModel, @unchecked Sendable {
    private let lock = NSLock()
    private let terminal: GhosttyVtTerminal

    /// - Parameter size: the grid the terminal was opened with.
    /// - Parameter scrollbackLines: how much history to keep, at most.
    /// - Parameter graphemeClustering: what the surface this model mirrors resolved
    ///   for it, `TerminalSurfaceHosting.graphemeClustering`.
    package init(size: TerminalSize,
                 scrollbackLines: Int = TerminalScrollback.lines,
                 graphemeClustering: Bool = true) throws {
        terminal = try GhosttyVtTerminal(size: size,
                                         scrollbackLines: scrollbackLines,
                                         graphemeClustering: graphemeClustering)
    }

    package func write(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        terminal.write(bytes)
    }

    package func resize(to size: TerminalSize) {
        lock.lock(); defer { lock.unlock() }
        terminal.resize(to: size)
    }

    package func paintFrame() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return terminal.paintFrame()
    }

    package func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return terminal.snapshot()
    }

    package func text(maxLines: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return terminal.text(maxLines: maxLines)
    }

    package var size: TerminalSize {
        lock.lock(); defer { lock.unlock() }
        return terminal.size
    }
}
