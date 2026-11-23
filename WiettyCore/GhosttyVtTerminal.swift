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
    ///   keeps none. The library prunes history a whole page at a time, so a
    ///   full scrollback holds between the limit and about one page under it,
    ///   depending on where in a page the last line fell: measured with short
    ///   log lines, 9,605 to 10,000 rows for 10,000 at 120 columns, 605 to 1,000
    ///   for 1,000, and 409 to 1,000 for 1,000 at 80 columns.
    /// - Parameter graphemeClustering: whether mode 2027 starts on, and comes back
    ///   on after a full reset. True is what a surface does under Ghostty's default
    ///   configuration; pass what the surface this terminal mirrors resolved.
    package init(size: TerminalSize, scrollbackLines: Int, graphemeClustering: Bool = true) throws {
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

        // Grapheme clustering (mode 2027) as the surface has it, and as the value a
        // reset restores. A bare libghostty-vt terminal starts with it off. A
        // libghostty surface starts with it on, because Ghostty's
        // `grapheme-width-method` defaults to `unicode`, and puts it back after a
        // full reset; a user who set that key to `legacy` has a surface that
        // starts with it off, which is why this is a parameter. The mode decides how many
        // cells an emoji made of several code points takes, so with it off this
        // terminal lays out a line holding one differently from the surface it is
        // meant to mirror whenever the two differ. Found by the coexistence check,
        // not by reading: it was the one kind of output on which the two disagreed.
        //
        // As a default rather than by writing `CSI ? 2027 h`, because a program
        // that sends a full reset (`reset`, `tput reset`) would otherwise turn it
        // off here and nowhere else.
        var clustering = GhosttyTerminalModeConfig(mode: Self.graphemeClusterMode,
                                                   value: graphemeClustering)
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

    /// Whether a mode is set right now. `ansi` false is a DEC private mode
    /// (`CSI ? n h`), true an ANSI one (`CSI n h`).
    package func isModeSet(_ number: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: Self.mode(number, ansi: ansi), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return false
        }
        return config.value
    }

    /// The kitty keyboard protocol flags in force on the active screen.
    package var kittyKeyboardFlags: UInt8 {
        var flags: UInt8 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
        return flags
    }

    /// `ghostty_mode_new`, which Swift does not see: the mode number in the low
    /// fifteen bits and the top bit set for an ANSI mode.
    private static func mode(_ number: UInt16, ansi: Bool) -> GhosttyMode {
        GhosttyMode((number & 0x7FFF) | (ansi ? 0x8000 : 0))
    }

    /// How many rows of history are held above the active screen right now.
    package var scrollbackRows: Int {
        count(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
    }

    /// VT that paints the visible viewport into a terminal that has just been
    /// reset: the cells with their colours and attributes, then the cursor, the
    /// modes, the scrolling region, the tab stops and the rest of what the
    /// formatter can carry, the palette excepted (see `paintExtras`).
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
                      extras: Self.paintExtras,
                      trim: false,
                      unwrap: false,
                      selection: selection)
    }

    /// VT that rebuilds this terminal in one that has just been hard reset: every
    /// row of history the terminal still holds, oldest first, then the active
    /// screen, then the cursor, the modes, the scrolling region, the tab stops and
    /// the rest of what `paintFrame()` carries, the palette excepted for the same
    /// reason (see `paintExtras`). With the grid and the screen it was taken on,
    /// read in the same call so the three always describe the same moment.
    ///
    /// The rows are one selection over the whole of the active screen, in the
    /// `screen` coordinate space that `text(maxLines:)` reads, from the first row
    /// of history to the last row of the active area, formatted once. The cost
    /// is linear in the rows held. Measured at 120 columns: about 630 KB and 2 ms
    /// for a full default scrollback of coloured log lines, 6.4 MB and 17 ms for
    /// 100,000 lines.
    ///
    /// Not trimmed, so the blank rows at the bottom of the screen are written and
    /// a receiver of the same grid ends with as many history rows as this
    /// terminal has, and the cursor lands on the same row. Unwrapped, which reads
    /// backwards but is what keeps a wrap a wrap: without it the formatter ends
    /// every row with a line break, and a line the terminal wrapped arrives as
    /// two lines that merely look the same. Joined, it is written as one line and
    /// the receiver wraps it again at the same column. The paint frame does not
    /// unwrap, so a line wrapped on a painted viewer looks right but is two
    /// lines to that viewer's copy and reflow.
    ///
    /// **The content is laid down with default modes, and the modes come after
    /// it.** The library writes the modes and the tab stops in front of the
    /// content, and the scrolling region, cursor, pen, keyboard protocols and
    /// character sets behind it. In front is harmless for a viewport, but not
    /// for wrapped history: with autowrap off the joined lines would be cut at
    /// the last column. So the frame is assembled from parts, in this order:
    ///
    /// 1. grapheme clustering, stated outright, because it decides how many
    ///    cells a joined emoji takes and a reset puts back the receiver's
    ///    default, not this terminal's;
    /// 2. the switch to the alternate screen, if this terminal is on it, so the
    ///    content lands there;
    /// 3. the content, formatted with no extras;
    /// 4. the other modes and then the tab stops, as the library wrote them;
    /// 5. everything the library writes behind the content, as it wrote it.
    ///
    /// Parts 2, 4 and 5 are cut out of the library's own output for the last row
    /// alone, which costs three passes over one row: the row with no extras, the
    /// row with only the extras written in front, and the row with all of them.
    /// Should a later release put that row anywhere else in its output, or write
    /// a different front for the two, the cut does not match and the frame falls
    /// back to the library's single pass, which is correct for everything but a
    /// mode that changes how content is laid down.
    ///
    /// On the alternate screen this is that screen and nothing else: the
    /// alternate screen has no history, and the formatter only reads the active
    /// screen, so the primary screen underneath is not in it.
    package func snapshotFrame() -> TerminalSnapshotFrame {
        let size = self.size
        let alternate = isAlternateScreen
        return TerminalSnapshotFrame(size: size, bytes: snapshotBytes(size: size), alternate: alternate)
    }

    private func snapshotBytes(size: TerminalSize) -> [UInt8] {
        let total = count(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS)
        guard let whole = selection(tag: GHOSTTY_POINT_TAG_SCREEN, firstRow: 0,
                                    lastRow: total - 1, cols: size.cols),
              let lastRow = selection(tag: GHOSTTY_POINT_TAG_SCREEN, firstRow: total - 1,
                                      lastRow: total - 1, cols: size.cols) else { return [] }
        func vt(_ extras: GhosttyFormatterExtras, _ selection: GhosttySelection) -> [UInt8] {
            format(emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: extras, trim: false, unwrap: true,
                   selection: selection)
        }

        // The row bare, the row behind what goes in front of it, and the row with
        // everything. The last is cut by the second rather than by the row: what
        // the library writes behind the content depends on what it wrote in front
        // (the cursor comes relative to the scrolling region when it has written
        // origin mode, and absolute when it has not), so the part behind is taken
        // from a pass that wrote both, exactly as the single pass would have it.
        let row = vt(GHOSTTY_FORMATTER_EXTRAS_NONE, lastRow)
        let infront = vt(Self.extrasInFront, lastRow)
        let everything = vt(Self.paintExtras, lastRow)
        guard infront.count >= row.count, infront.suffix(row.count).elementsEqual(row),
              everything.count >= infront.count, everything.prefix(infront.count).elementsEqual(infront) else {
            return vt(Self.paintExtras, whole)
        }
        let prefix = SnapshotPrefix(infront.dropLast(row.count))

        var bytes = Array("\u{1B}[?2027\(isModeSet(2027) ? "h" : "l")".utf8)
        bytes += prefix.screenSwitches
        bytes += vt(GHOSTTY_FORMATTER_EXTRAS_NONE, whole)
        bytes += prefix.otherModes
        bytes += prefix.rest
        bytes += everything.dropFirst(infront.count)
        return bytes
    }

    /// The extras the library writes in front of the content.
    private static let extrasInFront: GhosttyFormatterExtras =
        GHOSTTY_FORMATTER_EXTRA_MODES | GHOSTTY_FORMATTER_EXTRA_TABSTOPS

    /// What the library writes in front of the content, taken apart: the leading
    /// run of mode sets and resets (`CSI ? n h`, `CSI n l` and so on), one per
    /// sequence, and whatever follows them, the tab stops, kept as it is.
    private struct SnapshotPrefix {
        /// The alternate screen modes, which have to be in force before content.
        var screenSwitches: [UInt8] = []
        /// Every other mode, grapheme clustering excepted because the frame
        /// states it itself.
        var otherModes: [UInt8] = []
        var rest: [UInt8] = []

        private static let screenModes: Set<Int> = [47, 1047, 1049]

        init(_ bytes: ArraySlice<UInt8>) {
            var index = bytes.startIndex
            while let (sequence, number, isPrivate, end) = Self.mode(in: bytes, at: index) {
                if isPrivate && Self.screenModes.contains(number) {
                    screenSwitches += sequence
                } else if !(isPrivate && number == 2027) {
                    otherModes += sequence
                }
                index = end
            }
            rest = Array(bytes[index...])
        }

        /// One `ESC [ ? n h` or `ESC [ n l` starting at `start`, or nil.
        private static func mode(in bytes: ArraySlice<UInt8>, at start: Int)
            -> (ArraySlice<UInt8>, Int, Bool, Int)? {
            var index = start
            func next() -> UInt8? {
                guard index < bytes.endIndex else { return nil }
                defer { index += 1 }
                return bytes[index]
            }
            guard next() == 0x1B, next() == UInt8(ascii: "[") else { return nil }
            var isPrivate = false
            var number = 0
            var digits = 0
            while let byte = next() {
                switch byte {
                case UInt8(ascii: "?") where digits == 0 && !isPrivate:
                    isPrivate = true
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    number = number * 10 + Int(byte - UInt8(ascii: "0"))
                    digits += 1
                    guard digits <= 5 else { return nil }
                case UInt8(ascii: "h"), UInt8(ascii: "l"):
                    guard digits > 0 else { return nil }
                    return (bytes[start..<index], number, isPrivate, index)
                default:
                    return nil
                }
            }
            return nil
        }
    }

    /// Whether the alternate screen is the active one, as the library has it.
    package var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// Everything the formatter can restore except the palette.
    ///
    /// The palette extra writes all 256 entries with `OSC 4`, and what it writes
    /// is this terminal's own table, which nothing configures: the library's
    /// default colours, not the theme the surface draws with and not the theme
    /// of whoever is attaching. Sent to a viewer it would replace that viewer's
    /// colours with a third set for as long as it stays attached, and add about
    /// six kilobytes to every frame to do it. Without it a viewer keeps drawing
    /// indexed colours with its own theme, as it does for the stream. The one
    /// thing lost is a palette entry a program changed before the attach.
    private static let paintExtras: GhosttyFormatterExtras =
        GHOSTTY_FORMATTER_EXTRAS_ALL & ~GHOSTTY_FORMATTER_EXTRA_PALETTE

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
    /// A line is a line the program printed, not a row of the grid: one the
    /// terminal wrapped comes back joined, which is how a surface reports its
    /// text and what a reader counting lines means by one. Trailing spaces are
    /// removed from each line, and the blank rows below the last one with text
    /// are not lines at all, so a prompt at the top of an empty screen comes back
    /// as that one line rather than as a screenful.
    package func text(maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let size = self.size
        let total = count(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS)
        guard total > 0 else { return "" }
        // The last line with text is somewhere in the active screen or above it,
        // so the active screen plus one row per line asked for holds the answer
        // when nothing is wrapped. Formatting just that window, rather than
        // everything, is what keeps a small read cheap on a deep scrollback.
        //
        // One row more than that, and one line more than asked for before the
        // window is accepted: a window that does not start at the top of the
        // history can start in the middle of a wrapped line, and that first entry
        // is then the tail of a line, not a line. It is only ever dropped, never
        // returned.
        var window = min(total, size.rows + min(maxLines, total) + 1)
        while true {
            let first = total - window
            guard let selection = selection(tag: GHOSTTY_POINT_TAG_SCREEN,
                                            firstRow: first,
                                            lastRow: total - 1,
                                            cols: size.cols) else { return "" }
            let bytes = format(emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
                               extras: GHOSTTY_FORMATTER_EXTRAS_NONE,
                               trim: true,
                               unwrap: true,
                               selection: selection)
            let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
            // Wrapped lines make a window hold fewer lines than rows. Doubling
            // reaches the top of the history in a handful of steps at worst.
            if first == 0 || lines.count > maxLines {
                return lines.suffix(maxLines).joined(separator: "\n")
            }
            window = min(total, window * 2)
        }
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
