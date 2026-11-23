import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// The libghostty-vt wrapper on its own: bytes in, and the four things read back
/// out. No surface, no Metal device and no window, which is the point of the type.
///
/// What this suite cannot show is that the library behaves when a real libghostty
/// surface is live in the same process. That needs a window, so it is
/// `GhosttyVtCoexistenceTests`, which does not run unless asked for.
@Suite struct GhosttyVtTerminalTests {
    private static let esc = "\u{1b}"

    private func terminal(cols: Int = 80, rows: Int = 24, scrollback: Int = 1_000) throws -> GhosttyVtTerminal {
        try GhosttyVtTerminal(size: TerminalSize(cols: cols, rows: rows), scrollbackLines: scrollback)
    }

    private func write(_ text: String, to terminal: GhosttyVtTerminal) {
        terminal.write(Array(text.utf8))
    }

    private func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let needle = Array(needle.utf8)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    // MARK: - Text

    @Test func textIsWhatWasWritten() throws {
        let terminal = try terminal()
        write("first line\r\nsecond line\r\nthird", to: terminal)
        #expect(terminal.text(maxLines: 10) == "first line\nsecond line\nthird")
    }

    @Test func textCarriesNoEscapeSequences() throws {
        let terminal = try terminal()
        write("plain \(Self.esc)[1;31mred and bold\(Self.esc)[0m plain", to: terminal)
        #expect(terminal.text(maxLines: 1) == "plain red and bold plain")
    }

    @Test func textIsCappedToTheMostRecentLines() throws {
        let terminal = try terminal()
        write("one\r\ntwo\r\nthree\r\nfour", to: terminal)
        #expect(terminal.text(maxLines: 2) == "three\nfour")
        #expect(terminal.text(maxLines: 0) == "")
    }

    /// The read `readOutput` needs and a surface cannot give for a terminal that is
    /// not on screen: lines that have already scrolled off the top.
    @Test func textReachesIntoScrollback() throws {
        let terminal = try terminal(cols: 40, rows: 5)
        for line in 1...50 { write("line \(line)\r\n", to: terminal) }
        let lines = terminal.text(maxLines: 20).components(separatedBy: "\n")
        #expect(lines == (31...50).map { "line \($0)" })
        #expect(terminal.scrollbackRows > 0)
    }

    /// A line the terminal wrapped is one line of text, as a surface reports it.
    /// Whoever reads this counts lines a program printed, not rows of a grid they
    /// have never seen.
    @Test func aWrappedLineIsOneLineOfText() throws {
        let terminal = try terminal(cols: 10, rows: 6)
        write("0123456789abcdefghijKLMNO\r\nshort", to: terminal)
        #expect(terminal.viewportLines().count == 4)
        #expect(terminal.text(maxLines: 10) == "0123456789abcdefghijKLMNO\nshort")
    }

    /// The cap counts lines, so it has to keep looking further up while the rows
    /// it has read hold fewer lines than were asked for. Every line here takes
    /// four rows, on a grid that shows five, far up into the scrollback.
    @Test func theCapCountsLinesNotRows() throws {
        let terminal = try terminal(cols: 10, rows: 5)
        let body = String(repeating: "x", count: 32)
        for line in 1...60 { write("\(100 + line)\(body)\r\n", to: terminal) }
        let lines = terminal.text(maxLines: 25).components(separatedBy: "\n")
        #expect(lines == (36...60).map { "\(100 + $0)\(body)" })
    }

    /// A read that starts part of the way up the history can start in the middle
    /// of a wrapped line. The tail of that line is not a line, and must not come
    /// back as the first one.
    @Test func aLineCutByTheTopOfTheReadIsNotReturnedInPart() throws {
        let terminal = try terminal(cols: 10, rows: 3)
        for line in 1...40 { write("head\(100 + line)-tail-of-the-line\r\n", to: terminal) }
        for count in 1...12 {
            let lines = terminal.text(maxLines: count).components(separatedBy: "\n")
            #expect(lines.count == count)
            #expect(lines.allSatisfy { $0.hasPrefix("head") && $0.hasSuffix("-tail-of-the-line") },
                    "asked for \(count): \(lines)")
        }
    }

    /// Asking for more than there is returns what there is, and a number that
    /// large must not overflow the arithmetic on the way.
    @Test func askingForMoreLinesThanThereAreReturnsThemAll() throws {
        let terminal = try terminal(cols: 40, rows: 5)
        for line in 1...12 { write("line \(line)\r\n", to: terminal) }
        let lines = terminal.text(maxLines: .max).components(separatedBy: "\n")
        #expect(lines == (1...12).map { "line \($0)" })
    }

    /// A chunk boundary can fall anywhere, including inside an escape sequence or a
    /// multibyte character. The relay hands over whatever one read returned.
    @Test func aSequenceSplitAcrossWritesIsStillOneSequence() throws {
        let whole = try terminal()
        let split = try terminal()
        let bytes = Array("a\(Self.esc)[32mgréén\(Self.esc)[0m\(Self.esc)[2;5Hz".utf8)
        whole.write(bytes)
        for byte in bytes { split.write([byte]) }
        #expect(split.text(maxLines: 24) == whole.text(maxLines: 24))
        #expect(split.paintFrame() == whole.paintFrame())
        #expect(split.cursor == whole.cursor)
    }

    /// Mode 2027, which a libghostty surface starts with and a bare vt terminal
    /// does not. With it off the four people and three joiners below take eight
    /// cells instead of two, and every line holding such an emoji is laid out
    /// differently from the surface. It has to survive a full reset as well,
    /// because the surface restores it and a program can send one at any time.
    @Test func anEmojiJoinedFromSeveralCodePointsIsOneWideCell() throws {
        let terminal = try terminal()
        write("👨‍👩‍👧‍👦", to: terminal)
        #expect(terminal.cursor.x == 2)

        write("\(Self.esc)c👨‍👩‍👧‍👦", to: terminal)
        #expect(terminal.cursor.x == 2)
    }

    /// What a surface does for a user whose Ghostty config sets
    /// `grapheme-width-method = legacy`: every person is a wide cell of their own
    /// and the joiners take none. Through a reset too, for the same reason as above.
    @Test func withoutGraphemeClusteringAJoinedEmojiIsOneCellPairPerCodePoint() throws {
        let terminal = try GhosttyVtTerminal(size: TerminalSize(cols: 80, rows: 24),
                                             scrollbackLines: 100,
                                             graphemeClustering: false)
        write("👨‍👩‍👧‍👦", to: terminal)
        #expect(terminal.cursor.x == 8)

        write("\(Self.esc)c👨‍👩‍👧‍👦", to: terminal)
        #expect(terminal.cursor.x == 8)
    }

    // MARK: - The paint frame

    @Test func paintFrameCarriesColours() throws {
        let terminal = try terminal()
        write("\(Self.esc)[31mred\(Self.esc)[0m \(Self.esc)[38;2;10;20;30mtrue\(Self.esc)[0m", to: terminal)
        let frame = terminal.paintFrame()
        let plain = Array(terminal.text(maxLines: 24).utf8)
        // More than the text: the frame is the text plus what colours it.
        #expect(frame.count > plain.count)
        #expect(contains(frame, "red"))
        #expect(contains(frame, "\(Self.esc)["))
        #expect(contains(frame, "10;20;30") || contains(frame, "10:20:30"))
    }

    /// The cursor is the thing the old first frame had to guess. Asserted through a
    /// second terminal rather than by matching a sequence, because where the cursor
    /// ends up is the contract and which sequence put it there is not.
    @Test func paintFrameCarriesTheCursor() throws {
        let source = try terminal()
        write("prompt\(Self.esc)[10;20H", to: source)
        #expect(source.cursor == (x: 19, y: 9))

        let copy = try terminal()
        copy.write(source.paintFrame())
        #expect(copy.cursor == (x: 19, y: 9))
    }

    /// A mode the program set has to reach the viewer, or a full screen program
    /// attached to half way through draws into a terminal in the wrong state.
    /// Bracketed paste, and a hidden cursor.
    @Test func paintFrameCarriesModes() throws {
        let terminal = try terminal()
        let before = terminal.paintFrame()
        write("\(Self.esc)[?2004h\(Self.esc)[?25l", to: terminal)
        let frame = terminal.paintFrame()
        #expect(frame != before)
        #expect(contains(frame, "?2004h"))
        #expect(contains(frame, "?25l"))
    }

    @Test func paintFrameReproducesTheVisibleTextInAFreshTerminal() throws {
        let source = try terminal(cols: 60, rows: 12)
        for line in 1...40 {
            write("\(Self.esc)[3\(line % 8)mline \(line)\(Self.esc)[0m of the log\r\n", to: source)
        }
        write("\(Self.esc)[1mwide: 日本語 and é\(Self.esc)[0m\r\n", to: source)
        write("\(Self.esc)[4;10H\(Self.esc)[7mplaced\(Self.esc)[0m", to: source)

        let copy = try terminal(cols: 60, rows: 12)
        copy.write(source.paintFrame())

        #expect(copy.viewportLines() == source.viewportLines())
        #expect(!source.viewportLines().isEmpty)
        #expect(copy.cursor == source.cursor)
        // Painting a painted terminal gives the same frame again: nothing visible
        // was lost on the way through, colours included.
        #expect(copy.paintFrame() == source.paintFrame())
        // The viewport only. History stays behind.
        #expect(source.scrollbackRows > 0)
        #expect(copy.scrollbackRows == 0)
    }

    // MARK: - The snapshot

    @Test func snapshotIsNotEmpty() throws {
        let terminal = try terminal()
        #expect(!terminal.snapshot().isEmpty)
        let empty = terminal.snapshot().count
        for line in 1...200 { write("line \(line)\r\n", to: terminal) }
        // It carries the scrollback, so it grows with it.
        #expect(terminal.snapshot().count > empty)
    }

    // MARK: - The snapshot frame

    /// The history the source holds, then its screen, as numbered lines with a few
    /// the terminal had to wrap, so that a row that continues the one above it is
    /// part of what has to come across.
    private func fillWithHistory(_ terminal: GhosttyVtTerminal, lines: Int) {
        for line in 1...lines {
            if line % 50 == 0 {
                write("\(Self.esc)[3\(line % 8)mline \(line)\(Self.esc)[0m "
                      + String(repeating: "wrapped ", count: 25) + "\r\n", to: terminal)
            } else {
                write("\(Self.esc)[3\(line % 8)mline \(line)\(Self.esc)[0m of the log\r\n", to: terminal)
            }
        }
        write("\(Self.esc)[1mprompt$\(Self.esc)[0m half typed", to: terminal)
    }

    /// The snapshot is what a viewer attaching now is sent instead of a viewport:
    /// written behind a hard reset into a terminal that has seen nothing, it
    /// leaves the source's history and screen, and its cursor where the source
    /// has it.
    @Test func aSnapshotRebuildsHistoryAndScreenInAFreshTerminal() throws {
        let source = try terminal(cols: 80, rows: 40)
        fillWithHistory(source, lines: 300)

        let copy = try terminal(cols: 80, rows: 40)
        copy.write(TerminalPaint.hardReset + source.snapshotFrame().bytes)

        #expect(copy.text(maxLines: 300) == source.text(maxLines: 300))
        #expect(copy.text(maxLines: 300).hasPrefix("line "))
        #expect(copy.cursor == source.cursor)
        // Row for row, wrapped rows included: the history is rebuilt as rows, not
        // only as the lines they spell.
        #expect(copy.scrollbackRows == source.scrollbackRows)
        #expect(copy.viewportLines() == source.viewportLines())
        #expect(copy.paintFrame() == source.paintFrame())
    }

    /// The rows a reader is most likely to get wrong: a line exactly as wide as
    /// the grid, which sets no wrap; one a column wider, which wraps with one
    /// character on the next row; a wide character that does not fit in the last
    /// column and moves to the next row whole; and a screen whose rows below the
    /// cursor are blank. Each has to come across as the rows the source has, or
    /// the history ends a row short or long and the cursor lands on the wrong row.
    @Test func aSnapshotKeepsEveryRowAsTheSourceHasIt() throws {
        let source = try terminal(cols: 20, rows: 8)
        for line in 1...30 { write("row \(line)\r\n", to: source) }
        write(String(repeating: "x", count: 20) + "\r\n", to: source)
        write(String(repeating: "y", count: 21) + "\r\n", to: source)
        write(String(repeating: "z", count: 19) + "日本\r\n", to: source)
        write("\(Self.esc)[4mpartly underlined\(Self.esc)[0m\r\n", to: source)
        for line in 1...10 { write("tail \(line)\r\n", to: source) }
        // A cleared screen with two lines on it, and blank rows under the second.
        write("\(Self.esc)[H\(Self.esc)[2Jtop\(Self.esc)[4;6Hmiddle", to: source)

        let copy = try terminal(cols: 20, rows: 8)
        copy.write(TerminalPaint.hardReset + source.snapshotFrame().bytes)

        #expect(copy.scrollbackRows == source.scrollbackRows)
        #expect(copy.text(maxLines: 100) == source.text(maxLines: 100))
        #expect(copy.cursor == source.cursor)
        #expect(copy.viewportLines() == source.viewportLines())
        #expect(copy.paintFrame() == source.paintFrame())
        // And the copy's own snapshot is the source's: nothing was lost or added
        // on the way through, in the history either.
        #expect(copy.snapshotFrame() == source.snapshotFrame())
    }

    /// A viewer that already shows something: another program's alternate screen,
    /// with mouse reporting, a scrolling region, the kitty keyboard protocol and a
    /// history of its own. The hard reset in front of the snapshot has to clear all
    /// of it, or the history comes back with the viewer's old lines under it and
    /// the screen comes back inside the old scrolling region.
    @Test func aSnapshotIsCorrectOnADirtyTerminal() throws {
        let source = try terminal(cols: 80, rows: 40)
        fillWithHistory(source, lines: 300)

        let viewer = try terminal(cols: 80, rows: 40)
        for line in 1...200 { write("stale \(line) of the viewer\r\n", to: viewer) }
        // Kitty keyboard flags live on a stack per screen, so they are pushed on
        // both: once on the primary screen, and again once on the alternate one.
        write("\(Self.esc)[>1u", to: viewer)
        write("\(Self.esc)[?1049h\(Self.esc)[?1000h\(Self.esc)[5;10r\(Self.esc)[>3u", to: viewer)
        write("\(Self.esc)[7;3Hfull screen program", to: viewer)
        #expect(viewer.isAlternateScreen)
        #expect(viewer.kittyKeyboardFlags == 3)

        viewer.write(TerminalPaint.hardReset + source.snapshotFrame().bytes)

        #expect(viewer.text(maxLines: 300) == source.text(maxLines: 300))
        #expect(viewer.cursor == source.cursor)
        #expect(viewer.isAlternateScreen == source.isAlternateScreen)
        #expect(!viewer.text(maxLines: 10_000).contains("stale"))
        #expect(!viewer.text(maxLines: 10_000).contains("full screen program"))
        #expect(viewer.scrollbackRows == source.scrollbackRows)
        // Modes, margins and keyboard protocol as the source has them: the paint
        // frame carries all three, so equal frames mean none of the viewer's own
        // survived.
        #expect(viewer.paintFrame() == source.paintFrame())
        #expect(!viewer.isModeSet(1000))
        // The flags pushed on each screen are gone from both: the primary is the
        // active one now, and the alternate one is checked by entering it.
        #expect(viewer.kittyKeyboardFlags == 0)
        write("\(Self.esc)[?1049h", to: viewer)
        #expect(viewer.isAlternateScreen)
        #expect(viewer.kittyKeyboardFlags == 0)
    }

    /// The frame paints the active screen. A source on its alternate screen gives a
    /// viewer that is on its alternate screen too, showing what the program drew.
    @Test func aSnapshotOfTheAlternateScreenPutsTheViewerOnIt() throws {
        let source = try terminal(cols: 80, rows: 24)
        for line in 1...100 { write("shell line \(line)\r\n", to: source) }
        write("\(Self.esc)[?1049h\(Self.esc)[H\(Self.esc)[2Jeditor top\(Self.esc)[10;5Hcursor here", to: source)

        let viewer = try terminal(cols: 80, rows: 24)
        viewer.write(TerminalPaint.hardReset + source.snapshotFrame().bytes)

        #expect(viewer.isAlternateScreen)
        #expect(viewer.viewportLines() == source.viewportLines())
        #expect(viewer.cursor == source.cursor)
        #expect(viewer.paintFrame() == source.paintFrame())
    }

    // MARK: - The snapshot frame on a source with modes of its own

    /// History with lines wider than the 40 column grid, so they wrapped, written
    /// in letters that the DEC line drawing set would turn into box characters.
    private func fillWithWrappedLetters(_ terminal: GhosttyVtTerminal) {
        for line in 1...60 {
            if line % 7 == 0 {
                write("long \(line) " + String(repeating: "lqkxjm abc ", count: 6) + "\r\n", to: terminal)
            } else {
                write("letters lqkxjm \(line)\r\n", to: terminal)
            }
        }
    }

    /// Feeds `source`'s snapshot behind a hard reset into a fresh terminal of the
    /// same grid and checks the rows, the text, the cursor and the paint frame.
    @discardableResult
    private func rebuild(_ source: GhosttyVtTerminal,
                         sourceLocation: SourceLocation = #_sourceLocation) throws -> GhosttyVtTerminal {
        let copy = try terminal(cols: source.size.cols, rows: source.size.rows)
        copy.write(TerminalPaint.hardReset + source.snapshotFrame().bytes)
        #expect(copy.scrollbackRows == source.scrollbackRows, sourceLocation: sourceLocation)
        #expect(copy.text(maxLines: 500) == source.text(maxLines: 500), sourceLocation: sourceLocation)
        #expect(copy.cursor == source.cursor, sourceLocation: sourceLocation)
        #expect(copy.paintFrame() == source.paintFrame(), sourceLocation: sourceLocation)
        return copy
    }

    /// Autowrap off on the source: if the frame turned it off before laying down
    /// the history, every wrapped line would be cut at the last column.
    @Test func aSnapshotOfASourceWithAutowrapOffKeepsItsWrappedHistory() throws {
        let source = try terminal(cols: 40, rows: 10)
        fillWithWrappedLetters(source)
        write("\(Self.esc)[?7lafter", to: source)
        #expect(!source.isModeSet(7))

        let copy = try rebuild(source)
        #expect(!copy.isModeSet(7))
    }

    /// A scrolling region and origin mode on the source: applied before the
    /// history, the rows would scroll inside the region and never reach it.
    @Test func aSnapshotOfASourceWithARegionAndOriginModeKeepsItsHistory() throws {
        let source = try terminal(cols: 40, rows: 10)
        fillWithWrappedLetters(source)
        write("\(Self.esc)[3;8r\(Self.esc)[?6h\(Self.esc)[2;3Hin region", to: source)
        #expect(source.isModeSet(6))

        let copy = try rebuild(source)
        #expect(copy.isModeSet(6))
        // The region itself: a line feed at its bottom scrolls only inside it.
        write("\(Self.esc)[6;1H\n\n\nscrolled", to: source)
        write("\(Self.esc)[6;1H\n\n\nscrolled", to: copy)
        #expect(copy.viewportLines() == source.viewportLines())
        #expect(copy.scrollbackRows == source.scrollbackRows)
    }

    /// DEC line drawing as G0 on the source: designated before the history, the
    /// letters in it would come back as box characters.
    @Test func aSnapshotOfASourceUsingLineDrawingKeepsItsLetters() throws {
        let source = try terminal(cols: 40, rows: 10)
        fillWithWrappedLetters(source)
        write("\(Self.esc)(0lqqk", to: source)

        let copy = try rebuild(source)
        #expect(copy.text(maxLines: 500).contains("letters lqkxjm 1"))
        // And the receiver is left drawing lines, as the source is.
        write("lqk", to: source)
        write("lqk", to: copy)
        #expect(copy.viewportLines() == source.viewportLines())
    }

    /// Left and right margins (DECLRMM, then DECSLRM): applied before the history,
    /// every row would be laid down between columns 5 and 30.
    @Test func aSnapshotOfASourceWithLeftAndRightMarginsKeepsItsHistory() throws {
        let source = try terminal(cols: 40, rows: 10)
        fillWithWrappedLetters(source)
        write("\(Self.esc)[?69h\(Self.esc)[5;30s", to: source)
        #expect(source.isModeSet(69))

        let copy = try rebuild(source)
        #expect(copy.isModeSet(69))
        write("\(Self.esc)[1;1H" + String(repeating: "m", count: 35), to: source)
        write("\(Self.esc)[1;1H" + String(repeating: "m", count: 35), to: copy)
        #expect(copy.viewportLines() == source.viewportLines())
    }

    /// Grapheme clustering (mode 2027) is a default each terminal is built with,
    /// and a hard reset puts the receiver's own back. A source and a receiver that
    /// disagree about it would lay out a joined emoji in a different number of
    /// cells, so the frame states the source's value before any content, both
    /// ways round.
    @Test(arguments: [true, false])
    func aSnapshotStatesGraphemeClusteringBeforeItsContent(sourceClusters: Bool) throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let source = try GhosttyVtTerminal(size: TerminalSize(cols: 20, rows: 6), scrollbackLines: 1_000,
                                           graphemeClustering: sourceClusters)
        for line in 1...12 {
            write(String(repeating: "e", count: 14 + line % 4) + family + " tail \(line)\r\n", to: source)
        }
        write("prompt " + family, to: source)
        #expect(source.isModeSet(2027) == sourceClusters)

        let receiver = try GhosttyVtTerminal(size: TerminalSize(cols: 20, rows: 6), scrollbackLines: 1_000,
                                             graphemeClustering: !sourceClusters)
        let frame = source.snapshotFrame()
        let stated = Array("\(Self.esc)[?2027\(sourceClusters ? "h" : "l")".utf8)
        #expect(Array(frame.bytes.prefix(stated.count)) == stated)
        receiver.write(TerminalPaint.hardReset + frame.bytes)

        #expect(receiver.isModeSet(2027) == sourceClusters)
        #expect(receiver.scrollbackRows == source.scrollbackRows)
        #expect(receiver.text(maxLines: 100) == source.text(maxLines: 100))
        #expect(receiver.cursor == source.cursor)
    }

    /// The frame carries the grid and the flag it was taken with, read in the same
    /// call as its bytes.
    @Test func aSnapshotFrameCarriesItsGridAndFlag() throws {
        let terminal = try terminal(cols: 33, rows: 11)
        #expect(terminal.snapshotFrame().size == TerminalSize(cols: 33, rows: 11))
        #expect(!terminal.snapshotFrame().alternate)
        write("\(Self.esc)[?1049h", to: terminal)
        #expect(terminal.snapshotFrame().alternate)
    }

    /// The control for the dirty terminal test's last check: kitty keyboard flags
    /// pushed on the alternate screen are still there after leaving it and
    /// entering it again, with each of the three ways in. So flags found gone on
    /// the alternate screen after a hard reset were removed by the reset, not by
    /// the act of entering the screen to look.
    @Test(arguments: ["\u{1b}[?1049", "\u{1b}[?1047", "\u{1b}[?47"])
    func kittyFlagsOnTheAlternateScreenSurviveLeavingAndEnteringIt(mode: String) throws {
        let terminal = try terminal()
        write(mode + "h\(Self.esc)[>3u", to: terminal)
        #expect(terminal.kittyKeyboardFlags == 3)
        write(mode + "l", to: terminal)
        #expect(terminal.kittyKeyboardFlags == 0)
        write(mode + "h", to: terminal)
        #expect(terminal.kittyKeyboardFlags == 3)
    }

    /// A last row that is blank, with modes that go behind the content: the bare
    /// row is empty, which is a suffix of anything, and must be read as an
    /// empty row and not as a failed pass or a front that swallowed something.
    @Test func aSnapshotWhoseLastRowIsBlankKeepsEveryRow() throws {
        let source = try terminal(cols: 40, rows: 10)
        fillWithWrappedLetters(source)
        write("\(Self.esc)[H\(Self.esc)[2Jtop\r\nsecond\(Self.esc)[?7l\(Self.esc)[3;8r\(Self.esc)[?6h\(Self.esc)[2;5H", to: source)
        #expect(source.viewportLines().count < source.size.rows)

        let copy = try rebuild(source)
        #expect(!copy.isModeSet(7))
        #expect(copy.isModeSet(6))
        #expect(copy.viewportLines() == source.viewportLines())
    }

    /// DECCOLM (mode 3) with mode 40, which allows it. The library tracks both
    /// and acts on them: the source really goes to 132 columns and clears its
    /// screen. Both go in front of the content, in the order the library writes
    /// them, which is 3 before 40. On a receiver after a hard reset the 3 then
    /// finds 40 off and does nothing, so the receiver keeps the grid it was told
    /// and its screen, and is left allowing the switch as the source is. That
    /// holds even when the source was resized after the switch, which is the
    /// case where acting on 3 would be wrong.
    @Test func aSnapshotOfASourceThatSwitchedTo132ColumnsKeepsItsHistory() throws {
        let source = try terminal(cols: 40, rows: 10)
        fillWithWrappedLetters(source)
        write("\(Self.esc)[?40h\(Self.esc)[?3h", to: source)
        #expect(source.size.cols == 132)
        #expect(source.isModeSet(3) && source.isModeSet(40))
        for line in 1...15 { write("wide \(line) " + String(repeating: "w", count: 140) + "\r\n", to: source) }
        source.resize(to: TerminalSize(cols: 100, rows: 10))
        write("at 100", to: source)

        let frame = source.snapshotFrame()
        #expect(frame.size == TerminalSize(cols: 100, rows: 10))
        let copy = try terminal(cols: frame.size.cols, rows: frame.size.rows)
        copy.write(TerminalPaint.hardReset + frame.bytes)
        #expect(copy.size == frame.size)
        #expect(copy.scrollbackRows == source.scrollbackRows)
        #expect(copy.text(maxLines: 500) == source.text(maxLines: 500))
        #expect(copy.viewportLines() == source.viewportLines())
        #expect(copy.cursor == source.cursor)
        #expect(copy.isModeSet(40))
        // Not set on the receiver, and with no effect on it: see above. It is
        // also why the paint frames are not compared here: the source's states
        // mode 3 and the copy's does not.
        #expect(!copy.isModeSet(3))
    }

    /// A receiver that honours DECCOLM and does not forget mode 40 on a reset
    /// (SwiftTerm) would switch to 132 columns on the frame's `?3h`, clearing what
    /// it was told and changing its width. So the frame disallows the switch
    /// first, sets 3, and allows it again where the library puts 40.
    @Test func aSnapshotDisallowsTheColumnSwitchBeforeSettingMode3() throws {
        let source = try terminal(cols: 40, rows: 10)
        write("\(Self.esc)[?40h\(Self.esc)[?3h", to: source)
        source.resize(to: TerminalSize(cols: 100, rows: 10))
        #expect(source.isModeSet(3) && source.isModeSet(40))

        let bytes = source.snapshotFrame().bytes
        let disallow = try #require(bytes.firstRange(of: Array("\(Self.esc)[?40l".utf8)))
        let columns = try #require(bytes.firstRange(of: Array("\(Self.esc)[?3h".utf8)))
        let allow = try #require(bytes.firstRange(of: Array("\(Self.esc)[?40h".utf8)))
        #expect(disallow.upperBound <= columns.lowerBound)
        #expect(columns.upperBound <= allow.lowerBound)

        let copy = try terminal(cols: 100, rows: 10)
        copy.write(TerminalPaint.hardReset + bytes)
        #expect(copy.size == TerminalSize(cols: 100, rows: 10))
        #expect(copy.isModeSet(40))
    }

    /// A frame that cannot be cut stops the test host, where it is a bug to find,
    /// and is only logged everywhere else: a Debug build is what the app is run as
    /// day to day, and a terminal state nobody foresaw must not crash it.
    @Test func aFrameFaultStopsOnlyTheTestHost() {
        var logged: [String] = []
        var stopped: [String] = []
        TerminalFrameFault.report("cut", stopUnderTestHost: true, isTestHost: false,
                                  log: { logged.append($0) }, stop: { stopped.append($0) })
        #expect(logged == ["cut"])
        #expect(stopped.isEmpty)

        TerminalFrameFault.report("cut", stopUnderTestHost: true, isTestHost: true,
                                  log: { logged.append($0) }, stop: { stopped.append($0) })
        #expect(logged == ["cut", "cut"])
        #expect(stopped == ["cut"])
    }

    /// A failed format pass is logged and stops nothing, under the test host or
    /// not: a paint or a text read that fails has an answer to fall back on.
    @Test func aFailedFormatPassIsLoggedAndStopsNothing() {
        var logged: [String] = []
        var stopped: [String] = []
        TerminalFrameFault.report("pass", stopUnderTestHost: false, isTestHost: true,
                                  log: { logged.append($0) }, stop: { stopped.append($0) })
        #expect(logged == ["pass"])
        #expect(stopped.isEmpty)
    }

    @Test func theAlternateScreenFlagFollowsTheMode() throws {
        let terminal = try terminal()
        #expect(!terminal.isAlternateScreen)
        write("\(Self.esc)[?1049h", to: terminal)
        #expect(terminal.isAlternateScreen)
        write("\(Self.esc)[?1049l", to: terminal)
        #expect(!terminal.isAlternateScreen)
    }

    // MARK: - Size

    @Test func sizeIsTheSizeAskedFor() throws {
        #expect(try terminal(cols: 132, rows: 43).size == TerminalSize(cols: 132, rows: 43))
    }

    @Test func resizeChangesTheSize() throws {
        let terminal = try terminal()
        write("still here", to: terminal)
        terminal.resize(to: TerminalSize(cols: 120, rows: 40))
        #expect(terminal.size == TerminalSize(cols: 120, rows: 40))
        #expect(terminal.text(maxLines: 1) == "still here")
    }

    @Test func aSizeItCannotHoldIsRefused() throws {
        #expect(throws: GhosttyVtError.invalidSize(TerminalSize(cols: 0, rows: 24))) {
            _ = try GhosttyVtTerminal(size: TerminalSize(cols: 0, rows: 24), scrollbackLines: 100)
        }
        #expect(throws: GhosttyVtError.invalidSize(TerminalSize(cols: 80, rows: 70_000))) {
            _ = try GhosttyVtTerminal(size: TerminalSize(cols: 80, rows: 70_000), scrollbackLines: 100)
        }
        let terminal = try terminal()
        terminal.resize(to: TerminalSize(cols: 0, rows: 0))
        #expect(terminal.size == TerminalSize(cols: 80, rows: 24))
    }

    // MARK: - Scrollback

    /// The trap this pins: the library's byte limit defaults to 10,000 bytes, so a
    /// line limit set without it keeps about one page (557 rows when 10,000 were
    /// asked for). The limit is page granular, so the count held is somewhat under
    /// the one asked for, never exactly it.
    @Test func scrollbackHoldsRoughlyTheLinesAskedFor() throws {
        let terminal = try terminal(cols: 120, rows: 40, scrollback: 2_000)
        for line in 1...6_000 { write("line \(line) of some reasonably long log output\r\n", to: terminal) }
        #expect(terminal.scrollbackRows > 1_500)
        #expect(terminal.scrollbackRows <= 2_000)
        // The newest lines are the ones kept.
        #expect(terminal.text(maxLines: 1_000).hasSuffix("line 6000 of some reasonably long log output"))
    }

    @Test func aLargerLimitHoldsMore() throws {
        let small = try terminal(cols: 120, rows: 40, scrollback: 1_000)
        let large = try terminal(cols: 120, rows: 40, scrollback: 10_000)
        let chunk = Array((1...1_000).map { "line \($0) of some reasonably long log output\r\n" }.joined().utf8)
        for _ in 0..<15 {
            small.write(chunk)
            large.write(chunk)
        }
        #expect(small.scrollbackRows <= 1_000)
        #expect(large.scrollbackRows > 9_000)
        #expect(large.scrollbackRows <= 10_000)
    }

    @Test func zeroKeepsNoScrollback() throws {
        let terminal = try terminal(cols: 40, rows: 5, scrollback: 0)
        for line in 1...500 { write("line \(line)\r\n", to: terminal) }
        #expect(terminal.scrollbackRows == 0)
        #expect(terminal.text(maxLines: 100).components(separatedBy: "\n").count <= 5)
    }

    // MARK: - Silence

    /// A terminal emulator answers these by writing to the pty. This one must not,
    /// because the surface already does and a second answer is a wrong answer.
    ///
    /// The silence itself is not observable from here: the wrapper installs no
    /// write callback, so there is nowhere a reply could arrive to be counted.
    /// That is the mechanism, and it was measured directly against the C API before
    /// this type was written. What can be asserted is everything a reply could
    /// disturb if it were produced and looped back: the screen, the cursor, and the
    /// frame a viewer would be painted with.
    @Test func queriesAreSwallowedWithoutATrace() throws {
        let terminal = try terminal()
        write("before", to: terminal)
        let text = terminal.text(maxLines: 24)
        let cursor = terminal.cursor
        let frame = terminal.paintFrame()

        write("\(Self.esc)[c", to: terminal)        // primary device attributes
        write("\(Self.esc)[>c", to: terminal)       // secondary device attributes
        write("\(Self.esc)[5n", to: terminal)       // device status
        write("\(Self.esc)[6n", to: terminal)       // cursor position report
        write("\(Self.esc)[>q", to: terminal)       // XTVERSION
        write("\(Self.esc)[?2004$p", to: terminal)  // DECRQM

        #expect(terminal.text(maxLines: 24) == text)
        #expect(terminal.cursor == cursor)
        #expect(terminal.paintFrame() == frame)
    }

    /// Bell, title and notification all have callbacks in the library, and none is
    /// installed. With nothing installed they must be inert rather than a crash.
    @Test func sequencesWithCallbacksAreInert() throws {
        let terminal = try terminal()
        write("\u{7}", to: terminal)
        write("\(Self.esc)]0;a title\u{7}", to: terminal)
        write("\(Self.esc)]9;a notification\(Self.esc)\\", to: terminal)
        write("\(Self.esc)]777;notify;Build;Finished\(Self.esc)\\", to: terminal)
        write("\(Self.esc)]7;file://host/tmp\(Self.esc)\\", to: terminal)
        write("after", to: terminal)
        #expect(terminal.text(maxLines: 24) == "after")
    }

    // MARK: - Teardown

    /// Many short lived terminals, each with content and every kind of read taken
    /// from it. Under the address sanitizer this is the test that would report a
    /// double free or a buffer read after its terminal.
    @Test func terminalsCanBeCreatedAndFreedRepeatedly() throws {
        for round in 0..<50 {
            let terminal = try terminal(cols: 100, rows: 30, scrollback: 500)
            for line in 1...200 { write("round \(round) line \(line)\r\n", to: terminal) }
            #expect(!terminal.paintFrame().isEmpty)
            #expect(!terminal.snapshot().isEmpty)
            #expect(terminal.text(maxLines: 3).contains("round \(round) line 200"))
        }
    }
}
