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
