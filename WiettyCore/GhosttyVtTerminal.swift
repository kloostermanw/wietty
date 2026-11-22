import Foundation
// Private, so the C module stays out of this target's interface. The app and the
// test bundle import `WiettyCore` without depending on the package, and nothing
// outside this file may name a libghostty-vt type: the blast radius of a new
// release is meant to be one file, the rule `GhosttySurfaceHost` sets for
// GhosttyKit.
private import GhosttyVt

package enum GhosttyVtError: Error, Equatable {
    /// `ghostty_terminal_new` refused, with the library's own result code.
    case terminalFailed(code: Int32)
    /// A grid libghostty-vt cannot hold: a side that is zero or past `UInt16.max`.
    case invalidSize(TerminalSize)
}

/// A terminal with no window: libghostty-vt parsing a byte stream into a screen,
/// a scrollback and the modes a program set, all in memory.
///
/// This is the same emulation the libghostty surface runs, without a renderer, an
/// `NSView` or a child process. It exists so the core can answer "what is on this
/// terminal's screen" for a terminal nobody is looking at, which a surface cannot:
/// it only answers while it is on screen, in plain text, with no cursor.
///
/// **It never answers the program.** A terminal emulator replies to queries (device
/// attributes, cursor position, mode reports) by writing to the pty, and the
/// surface already does. A second answerer would not be noise, it would be a wrong
/// answer a program acts on, the moment the two disagree about any state. So
/// `GHOSTTY_TERMINAL_OPT_WRITE_PTY` is never set, which silences every reply, and no
/// other callback is installed either: bell, title and notification are already
/// reported by the surface through `GhosttyMonitor`, and a second report would ring
/// every bell twice.
///
/// **Not thread safe, and nothing in the library checks.** libghostty-vt's terminal
/// is not reentrant. Every call on one instance must be serialised by its owner;
/// this type deliberately carries no lock of its own, because the owner already
/// needs one to make a read line up with the byte offset it was taken at.
package final class GhosttyVtTerminal {
    /// `OpaquePointer` spelled out rather than `GhosttyTerminal`, so the class
    /// layout names nothing from a privately imported module.
    private let terminal: OpaquePointer

    /// - Parameter size: the grid to start with.
    /// - Parameter scrollbackLines: how many rows of history to keep, at most. Zero
    ///   keeps none. The library prunes history a page at a time, so a full
    ///   scrollback holds somewhat fewer rows than asked rather than exactly that
    ///   many: 10,000 gives about 9,665 at 120 columns, 1,000 about 953.
    package init(size: TerminalSize, scrollbackLines: Int) throws {
        guard let cols = UInt16(exactly: size.cols), let rows = UInt16(exactly: size.rows),
              cols > 0, rows > 0 else {
            throw GhosttyVtError.invalidSize(size)
        }
        var created: GhosttyTerminal?
        let result = ghostty_terminal_new(nil, &created, cols, rows)
        guard result == GHOSTTY_SUCCESS, let created else {
            throw GhosttyVtError.terminalFailed(code: Int32(result.rawValue))
        }
        terminal = created

        // Both limits, always together. The library's default byte limit is 10,000
        // BYTES, and whichever limit is reached first wins, so a line limit set
        // alone is silently capped at about one page: asking for 10,000 lines that
        // way was measured to keep 557. The line limit is the one this type
        // exposes, so the byte limit is lifted out of its way, except at zero,
        // where the byte limit is the documented way to turn history off.
        var lines = size_t(max(scrollbackLines, 0))
        var bytes: size_t = lines == 0 ? 0 : .max
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)

        // Grapheme clustering (mode 2027) on, and on as the value a reset restores.
        // A bare libghostty-vt terminal starts with it off. A libghostty surface
        // starts with it on, because Ghostty's `grapheme-width-method` defaults to
        // `unicode`, and puts it back after a full reset. The mode decides how many
        // cells an emoji made of several code points takes, so with it off this
        // terminal lays out a line holding one differently from the surface it is
        // meant to mirror. Found by the coexistence check, not by reading: it was
        // the one kind of output on which the two disagreed.
        //
        // As a default rather than by writing `CSI ? 2027 h`, because a program
        // that sends a full reset (`reset`, `tput reset`) would otherwise turn it
        // off here and nowhere else.
        var clustering = GhosttyTerminalModeConfig(mode: Self.graphemeClusterMode, value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &clustering)
    }

    /// DEC private mode 2027. The header builds this with an inline function Swift
    /// does not see as a constant: the mode number in the low fifteen bits, and the
    /// top bit clear because it is a DEC private mode and not an ANSI one.
    private static let graphemeClusterMode: GhosttyMode = 2027

    deinit {
        ghostty_terminal_free(terminal)
    }

    // MARK: - Writing

    /// Bytes from the pty, in stream order. A sequence split across two calls is
    /// carried over by the parser, so chunk boundaries do not matter.
    package func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_vt_write(terminal, buffer.baseAddress, buffer.count)
        }
    }

    /// Changes the grid. The primary screen reflows, as it does in the surface.
    ///
    /// A size the library cannot hold is ignored rather than thrown: the caller is
    /// relaying a size something else decided, and has nothing to do about a bad
    /// one except keep the grid it had.
    package func resize(to size: TerminalSize) {
        guard let cols = UInt16(exactly: size.cols), let rows = UInt16(exactly: size.rows),
              cols > 0, rows > 0 else { return }
        // Cell pixel size is zero: it only feeds pixel size reports, which are
        // replies, and this terminal sends none.
        ghostty_terminal_resize(terminal, cols, rows, 0, 0)
    }

    // MARK: - Reading

    /// The grid as the terminal holds it.
    package var size: TerminalSize {
        TerminalSize(cols: Int(uint16(GHOSTTY_TERMINAL_DATA_COLS)),
                     rows: Int(uint16(GHOSTTY_TERMINAL_DATA_ROWS)))
    }

    /// The cursor, zero based, within the active screen.
    package var cursor: (x: Int, y: Int) {
        (Int(uint16(GHOSTTY_TERMINAL_DATA_CURSOR_X)), Int(uint16(GHOSTTY_TERMINAL_DATA_CURSOR_Y)))
    }

    /// How many rows of history are held above the active screen right now.
    package var scrollbackRows: Int {
        count(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
    }

    /// VT that paints the visible viewport into a terminal that has just been
    /// reset: the cells with their colours and attributes, then the cursor, the
    /// modes, the palette, the scrolling region, the tab stops and the rest of what
    /// the formatter can carry.
    ///
    /// The viewport only, by a selection between its two corners. That is what a
    /// client attaching now needs, and it costs a hundredth of formatting the whole
    /// terminal with its scrollback. It does not carry the title, or the screen
    /// underneath an alternate screen; `snapshot()` is the only thing that does.
    ///
    /// Rows are not trimmed, so the frame fills exactly the rows the viewport has
    /// and a blank bottom half stays blank on the client.
    package func paintFrame() -> [UInt8] {
        let size = self.size
        guard let selection = selection(tag: GHOSTTY_POINT_TAG_VIEWPORT,
                                        firstRow: 0,
                                        lastRow: size.rows - 1,
                                        cols: size.cols) else { return [] }
        return format(emit: GHOSTTY_FORMATTER_FORMAT_VT,
                      extras: GHOSTTY_FORMATTER_EXTRAS_ALL,
                      trim: false,
                      unwrap: false,
                      selection: selection)
    }

    /// The whole terminal in libghostty-vt's snapshot format: both screens, the
    /// scrollback, the title and the modes. For restoring a terminal, not for
    /// painting one, and far too large to produce per attach (about 3 MB for a full
    /// 10,000 line scrollback).
    ///
    /// The byte format is versioned by the library and is not covered by its ABI
    /// promise, which is why the dependency is pinned by checksum.
    package func snapshot() -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length: size_t = 0
        guard ghostty_snapshot_encode_alloc(terminal, nil, &pointer, &length) == GHOSTTY_SUCCESS,
              let pointer else { return Data() }
        defer { ghostty_free(nil, pointer, length) }
        return Data(bytes: pointer, count: length)
    }

    /// The last `maxLines` lines of plain text, oldest first, reaching into
    /// scrollback when the visible screen holds fewer.
    ///
    /// One line per row of the grid: a line the terminal wrapped stays wrapped.
    /// Trailing spaces are removed from each line, and the blank rows below the
    /// last one with text are not lines at all, so a prompt at the top of an empty
    /// screen comes back as that one line rather than as a screenful.
    package func text(maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let size = self.size
        let total = count(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS)
        guard total > 0 else { return "" }
        // The last line with text is somewhere in the active screen or above it,
        // so `maxLines` rows above the active screen plus the active screen itself
        // always contain the lines asked for. Formatting just that window, rather
        // than everything, is what keeps a small read cheap on a deep scrollback.
        let first = max(total - size.rows - maxLines, 0)
        guard let selection = selection(tag: GHOSTTY_POINT_TAG_SCREEN,
                                        firstRow: first,
                                        lastRow: total - 1,
                                        cols: size.cols) else { return "" }
        let bytes = format(emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
                           extras: GHOSTTY_FORMATTER_EXTRAS_NONE,
                           trim: true,
                           unwrap: false,
                           selection: selection)
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// The visible viewport as plain text, one entry per row that has text or has a
    /// row with text below it.
    ///
    /// - Parameter unwrap: true joins a line the terminal wrapped back into one
    ///   entry, which is how `ghostty_surface_read_text` reports a viewport. It is
    ///   here so the two can be compared like for like.
    package func viewportLines(unwrap: Bool = false) -> [String] {
        let size = self.size
        guard let selection = selection(tag: GHOSTTY_POINT_TAG_VIEWPORT,
                                        firstRow: 0,
                                        lastRow: size.rows - 1,
                                        cols: size.cols) else { return [] }
        let bytes = format(emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
                           extras: GHOSTTY_FORMATTER_EXTRAS_NONE,
                           trim: true,
                           unwrap: unwrap,
                           selection: selection)
        guard !bytes.isEmpty else { return [] }
        return String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
    }

    // MARK: - The C API

    private func uint16(_ key: GhosttyTerminalData) -> UInt16 {
        var value: UInt16 = 0
        ghostty_terminal_get(terminal, key, &value)
        return value
    }

    private func count(_ key: GhosttyTerminalData) -> Int {
        var value: size_t = 0
        ghostty_terminal_get(terminal, key, &value)
        return Int(value)
    }

    /// A selection covering whole rows, from the first cell of `firstRow` to the
    /// last cell of `lastRow`, in the coordinate space `tag` names.
    ///
    /// Grid references are only valid until the next call that changes the
    /// terminal, so a selection is built for one format call and never kept.
    private func selection(tag: GhosttyPointTag, firstRow: Int, lastRow: Int, cols: Int) -> GhosttySelection? {
        guard firstRow >= 0, lastRow >= firstRow, cols > 0 else { return nil }
        var start = GhosttyPoint()
        start.tag = tag
        start.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(firstRow))
        var end = GhosttyPoint()
        end.tag = tag
        end.value.coordinate = GhosttyPointCoordinate(x: UInt16(cols - 1), y: UInt32(lastRow))

        var selection = GhosttySelection()
        guard ghostty_terminal_grid_ref(terminal, start, &selection.start) == GHOSTTY_SUCCESS,
              ghostty_terminal_grid_ref(terminal, end, &selection.end) == GHOSTTY_SUCCESS else {
            return nil
        }
        return selection
    }

    private func format(emit: GhosttyFormatterFormat,
                        extras: GhosttyFormatterExtras,
                        trim: Bool,
                        unwrap: Bool,
                        selection: GhosttySelection) -> [UInt8] {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal) == GHOSTTY_SUCCESS,
              let formatter else { return [] }
        defer { ghostty_formatter_free(formatter) }

        var emit = emit
        var extras = extras
        var trim = trim
        var unwrap = unwrap
        var selection = selection
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection)

        var pointer: UnsafeMutablePointer<UInt8>?
        var length: size_t = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS,
              let pointer else { return [] }
        defer { ghostty_free(nil, pointer, length) }
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }
}
