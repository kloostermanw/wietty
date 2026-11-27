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

    /// What a viewer that asked for repaints is sent after the grid moved: the
    /// grid, and the paint frame for behind `TerminalPaint.reset`, read together so
    /// a resize cannot land between them and pair one grid with the other's frame.
    /// Nil when no frame could be built, which the hub reads as a paint that failed
    /// rather than as an empty screen.
    ///
    /// The frame paints a terminal that has just been reset, and a viewer being
    /// repainted after a resize is not one, so the hub puts the soft reset in
    /// front of it: see `TerminalPaint.reset`.
    func repaintFrame() -> (size: TerminalSize, frame: [UInt8])?

    /// History up to the scrollback limit, then the visible screen with modes and cursor,
    /// as VT. Without a reset: `TerminalPaint.hardReset` goes in front of it.
    /// The grid and the screen it describes are read under the same lock as the
    /// bytes, so the three always belong together.
    ///
    /// What a viewer attaching now is sent so that it has the history as well as
    /// the screen. The active screen only: on the alternate screen it is that
    /// screen, and the primary screen underneath is not in it. Larger than a paint
    /// frame by the whole history, up to about a megabyte at 10,000 lines, and
    /// taken under the same lock as a write, so it is for an attach and never per
    /// frame.
    func snapshotFrame() -> TerminalSnapshotFrame

    /// Whether the alternate screen is the active one.
    var isAlternateScreen: Bool { get }

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
    /// For a conformance with no lock of its own to share between the two reads,
    /// such as a test's stand in. `GhosttyVtScreenModel` reads both in one
    /// critical section instead.
    package func repaintFrame() -> (size: TerminalSize, frame: [UInt8])? {
        let size = self.size
        let frame = paintFrame()
        guard !frame.isEmpty else { return nil }
        return (size, frame)
    }
}

/// A snapshot frame and what it was taken with, all read in one call.
///
/// A viewer is told the grid before the bytes, and a later step decides what to
/// do on the alternate screen from the flag. Read separately, a write could land
/// between the reads and the flag would describe a screen the bytes do not.
package struct TerminalSnapshotFrame: Sendable, Equatable {
    /// The grid the bytes were laid out for.
    package let size: TerminalSize
    /// `TerminalScreenModel.snapshotFrame()`'s VT, for behind `TerminalPaint.hardReset`.
    package let bytes: [UInt8]
    /// Whether the bytes leave the receiver on the alternate screen.
    package let alternate: Bool

    package init(size: TerminalSize, bytes: [UInt8], alternate: Bool) {
        self.size = size
        self.bytes = bytes
        self.alternate = alternate
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
    package static let reset: [UInt8] = Array("\u{1B}[!p\u{1B}[2J\u{1B}[H".utf8)

    /// What a snapshot frame is prefixed with: a full reset (RIS, `ESC c`).
    ///
    /// The snapshot rebuilds the history as well as the screen, so it needs the
    /// receiver in its power on state, which only a full reset gives: the
    /// scrollback and both screens emptied, the primary screen active, the
    /// margins, modes, mouse reporting and keyboard protocol back at their
    /// defaults. The repaint keeps using `reset`, which keeps a viewer's history.
    package static let hardReset: [UInt8] = [0x1B, 0x63]
}

/// How much history a terminal's model keeps.
///
/// One place, because the number is a memory decision: a retained row costs
/// roughly 1 KiB at 120 columns, so the default is about 10 MiB for a terminal
/// that has filled its scrollback, and thirty such terminals are about 300 MiB.
///
/// The number in force is a setting, `ProjectStore.scrollbackLines`. It is read
/// when a terminal opens: a model is built with its limit and keeps it.
package enum TerminalScrollback {
    /// Lines of history per terminal when nothing says otherwise. The library
    /// prunes a whole page at a time, so a full scrollback holds between its
    /// limit and about one page under it, never more.
    package static let defaultLines = 10_000

    /// What the setting may be.
    ///
    /// The floor is 1,000 lines, about 1 MiB: below it there is less to save
    /// than one terminal's surface already costs, and it stays well above the
    /// 200 lines an MCP read may ask for (`MCPToolRouter`), so no value of the
    /// setting shortens such a read. The ceiling is 100,000
    /// lines, about 100 MiB for one full terminal, which is where a typo in a
    /// hand edited config stops being able to take the machine with it.
    package static let range = 1_000...100_000

    /// `lines` brought into `range`.
    package static func clamped(_ lines: Int) -> Int {
        min(max(lines, range.lowerBound), range.upperBound)
    }
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
                 scrollbackLines: Int = TerminalScrollback.defaultLines,
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

    /// The grid and the frame in one critical section, for the same reason as
    /// `snapshotFrame()`: a resize arrives on the main actor while a repaint is
    /// taken on the hub's delivery queue.
    package func repaintFrame() -> (size: TerminalSize, frame: [UInt8])? {
        lock.lock(); defer { lock.unlock() }
        let frame = terminal.paintFrame()
        guard !frame.isEmpty else { return nil }
        return (terminal.size, frame)
    }

    /// The grid, the flag and the bytes in one critical section. That is what
    /// guarantees they describe the same moment; no test can catch a version
    /// that took two, because the gap between them is too small to hit.
    package func snapshotFrame() -> TerminalSnapshotFrame {
        lock.lock(); defer { lock.unlock() }
        return terminal.snapshotFrame()
    }

    package var isAlternateScreen: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminal.isAlternateScreen
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
