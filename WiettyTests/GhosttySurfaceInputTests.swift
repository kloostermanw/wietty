import Testing
import AppKit
@testable import Wietty

/// The two pure pieces of mouse forwarding.
///
/// Nothing else about input can be asserted without a live surface, and creating
/// one initialises libghostty, which `TerminalStackTests` asserts no other test
/// does. These two are where a silent mistake would live: a click landing on the
/// wrong row, or a scroll that a trackpad reports differently from a wheel.
@MainActor
@Suite struct GhosttySurfaceInputTests {
    /// libghostty's origin is the top left, an `NSView`'s is the bottom left, so
    /// the y axis is flipped. Getting this wrong puts every click and every drag
    /// selection on the mirrored row, which reads as a mysterious off by many
    /// rather than as an obvious flip.
    @Test func aViewPointIsFlippedOntoTheSurface() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(GhosttySurfaceView.surfacePoint(of: CGPoint(x: 10, y: 0), in: bounds)
            == CGPoint(x: 10, y: 300))
        #expect(GhosttySurfaceView.surfacePoint(of: CGPoint(x: 10, y: 300), in: bounds)
            == CGPoint(x: 10, y: 0))
        #expect(GhosttySurfaceView.surfacePoint(of: CGPoint(x: 40, y: 100), in: bounds)
            == CGPoint(x: 40, y: 200))
    }

    /// Bit 0 is "these deltas are precise", the bits above it hold the momentum
    /// phase. A wheel with no momentum is a zero, which is why the packing has to
    /// be right for anything else to be noticed at all.
    @Test func scrollModifiersPackPrecisionIntoBitZero() {
        #expect(GhosttySurfaceView.scrollMods(precision: false, momentum: 0) == 0)
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 0) == 1)
    }

    @Test func scrollModifiersPackMomentumAboveIt() {
        // The momentum values are `ghostty_input_mouse_momentum_e`'s own: 1 began,
        // 3 changed, 4 ended.
        #expect(GhosttySurfaceView.scrollMods(precision: false, momentum: 1) == 2)
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 1) == 3)
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 3) == 7)
        // Four needs a third momentum bit. A two bit mask would report this as
        // "none", so an inertial scroll would never be told it had stopped.
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 4) == 9)
    }

    // MARK: Drag and drop

    /// A path with nothing special still comes back quoted, because the shell the
    /// text lands in must read it as one literal argument whether or not it needs
    /// protecting.
    @Test func aPlainPathIsSingleQuoted() {
        #expect(GhosttySurfaceView.shellQuoted("/tmp/notes.txt") == "'/tmp/notes.txt'")
    }

    /// Spaces are the common case and the whole reason iTerm2 users reach for the
    /// drag: unquoted, `/tmp/my file.txt` would arrive as two arguments.
    @Test func spacesStayInsideTheQuotes() {
        #expect(GhosttySurfaceView.shellQuoted("/tmp/my file.txt") == "'/tmp/my file.txt'")
    }

    /// The one byte a single quoted string cannot hold. `it's` has to close the
    /// quote, emit an escaped quote, and reopen, or everything after it would be
    /// read as unquoted shell input.
    @Test func embeddedSingleQuotesAreEscaped() {
        #expect(GhosttySurfaceView.shellQuoted("/tmp/it's here.txt") == "'/tmp/it'\\''s here.txt'")
        #expect(GhosttySurfaceView.shellQuoted("a'b") == "'a'\\''b'")
    }

    /// A newline in a filename stays inside the quotes, so the shell reads a
    /// multi-line quoted argument rather than running the second line.
    @Test func newlinesStayInsideTheQuotes() {
        #expect(GhosttySurfaceView.shellQuoted("a\nb") == "'a\nb'")
    }

    /// One file inserts one quoted path.
    @Test func oneDroppedFileInsertsItsQuotedPath() {
        let text = GhosttySurfaceView.insertionText(forDroppedFiles: [URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(text == "'/tmp/a.txt'")
    }

    /// Several files join with a single space and no trailing newline, so the line
    /// waits at the cursor for the user to press return rather than submitting on
    /// drop.
    @Test func manyDroppedFilesJoinWithSpacesAndNoTrailingNewline() {
        let text = GhosttySurfaceView.insertionText(forDroppedFiles: [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b c.txt"),
        ])
        #expect(text == "'/tmp/a.txt' '/tmp/b c.txt'")
        #expect(!text.hasSuffix("\n"))
    }

    /// Nothing dropped is empty text, which `sendText` then ignores.
    @Test func noDroppedFilesIsEmptyText() {
        #expect(GhosttySurfaceView.insertionText(forDroppedFiles: []) == "")
    }

    /// A pasteboard carrying file URLs is read as those URLs, in order.
    @Test func fileURLsAreReadFromThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "wietty.test.drop.files"))
        pasteboard.clearContents()
        let a = URL(fileURLWithPath: "/tmp/a.txt")
        let b = URL(fileURLWithPath: "/tmp/b c.txt")
        pasteboard.writeObjects([a as NSURL, b as NSURL])

        #expect(GhosttySurfaceView.canDropFiles(on: pasteboard))
        #expect(GhosttySurfaceView.fileURLs(on: pasteboard).map(\.path) == [a.path, b.path])
    }

    /// A drag that is only text is not a file drop, so the pane refuses it and
    /// draws no highlight.
    @Test func aTextOnlyPasteboardCarriesNoFiles() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "wietty.test.drop.text"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)

        #expect(!GhosttySurfaceView.canDropFiles(on: pasteboard))
        #expect(GhosttySurfaceView.fileURLs(on: pasteboard).isEmpty)
    }
}
