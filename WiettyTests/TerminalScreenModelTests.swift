import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// Set once by the writer, read by every reader. Lock guarded rather than a
/// captured `var`, for the reason `GhosttyServiceTests` gives for its sinks: the
/// tasks that share it are `@Sendable`.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// The model through its protocol, which is all the rest of the core may use, and
/// the one thing the conformance adds to the wrapper underneath it: a lock.
///
/// What the bytes mean is `GhosttyVtTerminalTests`' subject and is not repeated
/// here. This suite is about the contract a reader of `TerminalScreenModel` is
/// promised, and about calling it from several threads at once.
@Suite struct TerminalScreenModelTests {
    private static let esc = "\u{1b}"

    private func model(cols: Int = 80, rows: Int = 24) throws -> any TerminalScreenModel {
        try GhosttyVtScreenModel(size: TerminalSize(cols: cols, rows: rows))
    }

    private func write(_ text: String, to model: any TerminalScreenModel) {
        model.write(Array(text.utf8))
    }

    @Test func textIsWhatWasWrittenMostRecentLinesLast() throws {
        let model = try model()
        write("first\r\n\(Self.esc)[32msecond\(Self.esc)[0m\r\nthird", to: model)
        #expect(model.text(maxLines: 10) == "first\nsecond\nthird")
        #expect(model.text(maxLines: 2) == "second\nthird")
    }

    /// The paint frame is the whole point of the model: written into a terminal
    /// that has seen nothing else, it has to leave the screen the source has.
    /// Compared by painting the copy again, so colours and cursor are covered and
    /// not only the text.
    @Test func aPaintFrameReproducesTheScreenInAFreshModel() throws {
        let source = try model(cols: 60, rows: 12)
        for line in 1...30 {
            write("\(Self.esc)[3\(line % 8)mline \(line)\(Self.esc)[0m of the log\r\n", to: source)
        }
        write("\(Self.esc)[5;8H\(Self.esc)[7mplaced\(Self.esc)[0m", to: source)

        let copy = try model(cols: 60, rows: 12)
        copy.write(source.paintFrame())

        // The copy has the viewport and nothing above it, so its text is the end
        // of the source's, which still has its history.
        let painted = copy.text(maxLines: 12)
        #expect(painted.contains("placed"))
        #expect(painted.contains("line 30 of the log"))
        #expect(!painted.contains("line 1 of the log"))
        #expect(source.text(maxLines: 40).hasSuffix(painted))
        #expect(copy.paintFrame() == source.paintFrame())
    }

    /// What a viewer is actually sent: its grid, and then one payload that starts
    /// from a reset and ends with the cursor where the terminal has it. The size
    /// leads because a viewer learns its grid from this message and from nothing
    /// else on the socket.
    @Test func paintMessagesAreTheGridThenAFrameThatStartsFromAReset() throws {
        let model = try model(cols: 20, rows: 4)
        write("ab\r\n\(Self.esc)[31mcd\(Self.esc)[0m", to: model)
        let messages = model.paintMessages()
        #expect(messages.count == 2)
        #expect(messages.first == .resize(cols: 20, rows: 4))
        guard case let .data(vt) = try #require(messages.last) else {
            Issue.record("expected the frame")
            return
        }
        #expect(vt.hasPrefix(TerminalPaint.reset))
        // Coloured, which the frame this replaced could not be.
        #expect(vt.contains("\(Self.esc)[38;5;1m"))

        let viewer = try GhosttyVtTerminal(size: TerminalSize(cols: 20, rows: 4), scrollbackLines: 0)
        viewer.write(Array(vt.utf8))
        #expect(viewer.viewportLines() == ["ab", "cd"])
        #expect(viewer.cursor == (x: 2, y: 1))
    }

    /// A repaint lands on a viewer that already shows something. The frame only
    /// writes the rows the terminal has, so without the reset in front of it a
    /// longer old line would show through, and with margins or origin mode left
    /// over from before, the rows would be painted inside the old scrolling region.
    @Test func aPaintOverAScreenThatHoldsSomethingLeavesNothingBehind() throws {
        let model = try model(cols: 30, rows: 6)
        write("short\r\nnew", to: model)

        let viewer = try GhosttyVtTerminal(size: TerminalSize(cols: 30, rows: 6), scrollbackLines: 0)
        viewer.write(Array("a much longer line than that\r\nand another\r\nand a third".utf8))
        viewer.write(Array("\(Self.esc)[2;4r\(Self.esc)[?6h\(Self.esc)[1;7mleft over".utf8))
        guard case let .data(vt) = try #require(model.paintMessages().last) else {
            Issue.record("expected the frame")
            return
        }
        viewer.write(Array(vt.utf8))

        #expect(viewer.viewportLines() == ["short", "new"])
        #expect(viewer.cursor == (x: 3, y: 1))
        // And nothing of the old state survives it: painting the viewer again
        // gives the frame the model gives.
        #expect(viewer.paintFrame() == model.paintFrame())
    }

    /// A model with nothing to paint sends nothing, and the hub reads that as a
    /// paint that could not be built. Only a conformance that cannot format can
    /// produce it, so it is pinned on one.
    @Test func noFrameIsNoMessages() {
        final class Blank: TerminalScreenModel, @unchecked Sendable {
            func write(_ bytes: [UInt8]) {}
            func resize(to size: TerminalSize) {}
            func paintFrame() -> [UInt8] { [] }
            func snapshotFrame() -> TerminalSnapshotFrame {
                TerminalSnapshotFrame(size: size, bytes: [], alternate: false)
            }
            func snapshot() -> Data { Data() }
            func text(maxLines: Int) -> String { "" }
            var size: TerminalSize { TerminalSize(cols: 80, rows: 24) }
            var isAlternateScreen: Bool { false }
        }
        #expect(Blank().paintMessages().isEmpty)
    }

    /// The hard reset is the two bytes `ESC c` and nothing else: the snapshot is
    /// built for a terminal in its power on state, and RIS is what puts one there.
    @Test func theHardResetIsRIS() {
        #expect(TerminalPaint.hardReset == [0x1B, 0x63])
    }

    /// Through the protocol, so the flag a later caller decides on is the one the
    /// model keeps.
    @Test func theAlternateScreenFlagFollowsTheMode() throws {
        let model = try model()
        #expect(!model.isAlternateScreen)
        write("\(Self.esc)[?1049h", to: model)
        #expect(model.isAlternateScreen)
        write("\(Self.esc)[?1049l", to: model)
        #expect(!model.isAlternateScreen)
    }

    /// The snapshot carries the history the model keeps and no more: a model with
    /// a thousand lines of scrollback that was fed five thousand gives a frame a
    /// fresh terminal with far more room reads back as the kept history and one
    /// screen.
    @Test func aSnapshotStopsAtTheScrollbackLimit() throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: 80, rows: 40), scrollbackLines: 1_000)
        for line in 1...5_000 { write("line \(line)\r\n", to: model) }

        let viewer = try GhosttyVtTerminal(size: TerminalSize(cols: 80, rows: 40), scrollbackLines: 20_000)
        viewer.write(TerminalPaint.hardReset + model.snapshotFrame().bytes)

        let lines = viewer.text(maxLines: 20_000).components(separatedBy: "\n")
        #expect(lines.count <= 1_040)
        // The library prunes a page at a time, so the model keeps between its
        // limit and about one page under it: 856 lines here, screen included.
        #expect(lines.count > 400, "\(lines.count) lines")
        #expect(lines.last == "line 5000")
        #expect(viewer.text(maxLines: 20_000) == model.text(maxLines: 20_000))
    }

    @Test func aSnapshotIsNotEmptyAndGrowsWithTheScrollback() throws {
        let model = try model()
        let empty = model.snapshot().count
        #expect(empty > 0)
        for line in 1...200 { write("line \(line)\r\n", to: model) }
        #expect(model.snapshot().count > empty)
    }

    @Test func aResizeChangesTheGridAndKeepsTheText() throws {
        let model = try model()
        #expect(model.size == TerminalSize(cols: 80, rows: 24))
        write("still here", to: model)
        model.resize(to: TerminalSize(cols: 132, rows: 43))
        #expect(model.size == TerminalSize(cols: 132, rows: 43))
        #expect(model.text(maxLines: 1) == "still here")
    }

    /// The default is the one named constant, and both of the library's limits are
    /// lifted to it: more lines than the constant are written, and far more than
    /// the single page a line limit set alone would keep are still there.
    @Test func theDefaultScrollbackIsTheNamedLimit() throws {
        #expect(TerminalScrollback.defaultLines == 10_000)
        let model = try model(cols: 40, rows: 10)
        for line in 1...12_000 { write("line \(line)\r\n", to: model) }
        let lines = model.text(maxLines: 20_000).components(separatedBy: "\n")
        #expect(lines.count > 8_000)
        #expect(lines.count <= TerminalScrollback.defaultLines + 10)
        #expect(lines.last == "line 12000")
    }

    /// The flag and the bytes are taken in one call under one lock. With one
    /// thread switching screens as fast as it can and another taking frames,
    /// every frame's flag is what its own bytes do to a receiver: a frame whose
    /// flag and bytes were read on either side of a write would disagree.
    @Test func aSnapshotFrameFlagAgreesWithItsBytesUnderConcurrentWrites() async throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: 40, rows: 10), scrollbackLines: 1_000)
        for line in 1...50 { write("history \(line)\r\n", to: model) }
        let finished = Finished()

        // Bounded by the frames taken rather than by the writes: frames are taken
        // until each screen has been caught a hundred times, so the test neither
        // ends before the writer is under way nor runs for as long as it can.
        let frames = await withTaskGroup(of: [TerminalSnapshotFrame].self) { group in
            group.addTask {
                var round = 0
                while !finished.isSet {
                    round += 1
                    model.write(Array("\u{1b}[?1049h\(round) on the alternate screen".utf8))
                    model.write(Array("\u{1b}[?1049l\(round) on the primary\r\n".utf8))
                }
                return []
            }
            group.addTask {
                var taken: [TerminalSnapshotFrame] = []
                var alternate = 0
                while min(alternate, taken.count - alternate) < 100 && taken.count < 50_000 {
                    let frame = model.snapshotFrame()
                    if frame.alternate { alternate += 1 }
                    taken.append(frame)
                    await Task.yield()
                }
                finished.set()
                return taken
            }
            var all: [TerminalSnapshotFrame] = []
            for await batch in group { all += batch }
            return all
        }

        #expect(!frames.isEmpty)
        var disagreements = 0
        for frame in frames {
            let receiver = try GhosttyVtTerminal(size: frame.size, scrollbackLines: 1_000)
            receiver.write(TerminalPaint.hardReset + frame.bytes)
            if receiver.isAlternateScreen != frame.alternate { disagreements += 1 }
        }
        #expect(disagreements == 0)
        // Both screens were caught, or the test showed nothing.
        #expect(frames.filter(\.alternate).count >= 100)
        #expect(frames.filter { !$0.alternate }.count >= 100)
    }

    /// A snapshot frame of a full default scrollback at 120 columns: within loose
    /// bounds of size and rows, so a change that made it quadratic or dropped the
    /// history would show. The numbers in `docs/terminal.md` come from this.
    @Test func aSnapshotFrameOfAFullScrollbackIsLinearInSize() throws {
        let model = try GhosttyVtScreenModel(size: TerminalSize(cols: 120, rows: 40))
        var chunk: [UInt8] = []
        for line in 1...12_000 {
            chunk += Array("\u{1b}[3\(line % 8)mline \(line)\u{1b}[0m of some reasonably long log output\r\n".utf8)
            if chunk.count > 65_536 { model.write(chunk); chunk = [] }
        }
        model.write(chunk)
        let rows = model.text(maxLines: 20_000).components(separatedBy: "\n").count
        let start = Date()
        let frame = model.snapshotFrame()
        let elapsed = Date().timeIntervalSince(start)
        // Between the limit and about one page (some 400 rows at 120 columns)
        // under it, plus the screen.
        #expect(rows > TerminalScrollback.defaultLines - 500)
        #expect(rows <= TerminalScrollback.defaultLines + 40)
        // About 65 bytes a row for these lines: 633 KB measured.
        #expect(frame.bytes.count > 400_000)
        #expect(frame.bytes.count < 1_500_000)
        #expect(elapsed < 1.0, "\(elapsed) s")
    }

    /// The three callers the model really has, at once: the relay's queue writing,
    /// the main actor resizing, and readers asking for a paint, the text and the
    /// grid. libghostty-vt is not reentrant, so without the lock this walks pages
    /// the parser is rewriting and crashes or reads garbage. With it, every line
    /// written arrives, in order, whatever was read in between.
    ///
    /// Both grids are wider than the longest line, so a resize reflows nothing and
    /// the text at the end is exactly what was written.
    @Test func writesResizesAndReadsFromSeveralThreadsLeaveTheTextIntact() async throws {
        let model = try model(cols: 80, rows: 24)
        let finished = Finished()
        let lineCount = 6_000

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // Uneven chunks, so sequences and lines are split across writes the
                // way one read from a pty splits them.
                var pending: [UInt8] = []
                for line in 1...lineCount {
                    pending += Array("\u{1b}[3\(line % 8)mline \(line)\u{1b}[0m\r\n".utf8)
                    if pending.count > 700 + line % 300 {
                        let cut = pending.count - line % 7
                        model.write(Array(pending[..<cut]))
                        pending = Array(pending[cut...])
                    }
                }
                model.write(pending)
                finished.set()
            }
            group.addTask {
                var wide = false
                while !finished.isSet {
                    wide.toggle()
                    model.resize(to: TerminalSize(cols: wide ? 100 : 80, rows: wide ? 30 : 24))
                    // Paced like a window drag rather than spun. A change of
                    // columns reflows the whole scrollback under the lock, so a
                    // resizer in a tight loop measures nothing but that.
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            for reader in 0..<4 {
                group.addTask {
                    var reads = 0
                    while !finished.isSet {
                        reads += 1
                        switch (reader + reads) % 4 {
                        case 0: _ = model.paintFrame()
                        case 1: _ = model.text(maxLines: 50)
                        case 2: _ = model.size
                        // Rarely, as its own contract asks: it is the expensive one.
                        default: if reads % 200 == 0 { _ = model.snapshot() }
                        }
                        await Task.yield()
                    }
                }
            }
        }

        let tail = model.text(maxLines: 2_000).components(separatedBy: "\n")
        #expect(tail == ((lineCount - 1_999)...lineCount).map { "line \($0)" })
        #expect(!model.paintFrame().isEmpty)
    }
}
