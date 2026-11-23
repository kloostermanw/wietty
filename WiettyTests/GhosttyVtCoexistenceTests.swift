import AppKit
import Darwin
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// libghostty and libghostty-vt, both live in one process, parsing the same bytes.
///
/// The two archives share several hundred symbols (simdutf, Google Highway, the
/// compiler builtins), and nothing before this had run them together with a real
/// surface: the earlier link test created no surface, so most of both libraries was
/// dead stripped away. Here a surface renders through Metal in a real window while a
/// `GhosttyVtTerminal` parses the same stream on another thread, and after every
/// segment the surface's visible grid, read with `ghostty_surface_read_text`, is
/// compared against the vt terminal's.
///
/// **This does not run in the normal suite, by design.** It needs a window and a
/// Metal device, which is exactly what `FakeSurfaceHost` exists to keep out of every
/// other test. It runs only when `WIETTY_COEXISTENCE_CHECK=1` is in the environment,
/// and the one supported way to run it is `scripts/coexistence-check.sh`, which also
/// turns the address sanitizer on. Without the variable the suite is reported as
/// skipped.
///
/// With `WIETTY_COEXISTENCE_GRAPHEME=legacy` as well, the surface is built from a
/// configuration that sets `grapheme-width-method = legacy`, and the vt terminal is
/// built the way `GhosttyService` builds a model: with whatever the host resolved.
/// That is the run that shows the two still agree on emoji for a user who chose
/// that setting. `scripts/coexistence-check.sh` passes the variable through.
///
/// It builds a `GhosttySurfaceHost` of its own beside the one the hosting app built
/// at launch. The host's callbacks reach "the current host" through a static, so
/// the app's own host stops being ticked once this one exists. Nothing else runs in
/// the process when this suite is asked for, which is the other reason it is never
/// part of a normal run.
@MainActor
@Suite(.enabled(if: CoexistenceCheck.isRequested)) struct GhosttyVtCoexistenceTests {
    /// The vt terminal crosses to a background task to be fed while the surface
    /// renders on its own threads. One writer at a time, and no reads until it is
    /// done, so the box is all the synchronisation there is to do.
    private final class Feed: @unchecked Sendable {
        let terminal: GhosttyVtTerminal
        init(_ terminal: GhosttyVtTerminal) { self.terminal = terminal }
    }

    @Test func aLiveSurfaceAndAVtTerminalAgreeOnTheSameBytes() async throws {
        let directory = TestScratch.root
            .appendingPathComponent("wietty-coexistence-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The surface's child. libghostty spawns and owns it and offers no byte
        // feed, so the bytes reach the surface the only way they can: something
        // running in its pty prints them. Raw mode first, so the line discipline
        // passes every byte through untouched, then one segment at a time, each
        // released by a file this test creates once the last one was compared.
        let kinds = CoexistenceStream.Kind.allCases
        let script = """
        stty raw -echo
        i=0
        while [ $i -lt \(kinds.count) ]; do
          while [ ! -e "\(directory.path)/go.$i" ]; do sleep 0.02; done
          cat "\(directory.path)/segment.$i"
          i=$((i+1))
        done
        exec sleep 600
        """
        let scriptURL = directory.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // The overlay is the sandbox's under a test host, and the host built below
        // loads it after the user's own config, so this decides the setting
        // whatever that config says.
        let overlay = GhosttyOverrideFile.defaultURL
        if CoexistenceCheck.legacyGraphemes {
            try FileManager.default.createDirectory(at: overlay.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "grapheme-width-method = legacy\n".write(to: overlay, atomically: true, encoding: .utf8)
        }
        defer { if CoexistenceCheck.legacyGraphemes { try? FileManager.default.removeItem(at: overlay) } }

        let host = try GhosttySurfaceHost()
        if CoexistenceCheck.legacyGraphemes { #expect(host.graphemeClustering == false) }
        let id = "coexistence"
        try host.createSurface(id: id, command: "/bin/sh \(scriptURL.path)", directory: directory, title: nil)
        defer { host.destroySurface(id: id) }

        // On screen, because a surface only draws, and only answers a read, while
        // its view is in a window.
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let view = try #require(host.view(id: id))
        view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.close() }

        let size = try await settledSize(of: id, in: host)
        let terminal = try GhosttyVtTerminal(size: size,
                                             scrollbackLines: 10_000,
                                             graphemeClustering: host.graphemeClustering)

        var totalBytes = 0
        var cellsCompared = 0
        var generator = CoexistenceStream(size: size, seed: 0x5EED_0084)
        for (index, kind) in kinds.enumerated() {
            let marker = "== segment \(index) \(kind.rawValue) complete =="
            let bytes = generator.segment(kind, marker: marker)
            totalBytes += bytes.count
            try Data(bytes).write(to: directory.appendingPathComponent("segment.\(index)"))

            // Both at once: the child starts printing into the surface, whose IO
            // and render threads take it from there, while the vt terminal parses
            // the same bytes on a thread of its own in uneven chunks.
            FileManager.default.createFile(atPath: directory.appendingPathComponent("go.\(index)").path,
                                           contents: nil)
            let feed = Feed(terminal)
            let chunks = generator.chunkSizes(for: bytes.count)
            await Task.detached {
                var offset = 0
                for chunk in chunks {
                    feed.terminal.write(Array(bytes[offset..<(offset + chunk)]))
                    offset += chunk
                }
            }.value

            let surfaceRows = try await rows(of: id, in: host, endingWith: marker)
            let vtRows = Self.normalised(terminal.viewportLines(unwrap: true))
            cellsCompared += size.cols * size.rows

            #expect(host.size(id: id) == size, "the surface's grid moved during segment \(index)")
            #expect(terminal.size == size)
            if surfaceRows != vtRows {
                Issue.record("""
                segment \(index) (\(kind.rawValue)): the surface and the vt terminal disagree.
                \(Self.firstDifference(surface: surfaceRows, vt: vtRows))
                """)
            }
        }

        #expect(totalBytes > 4 * 1_048_576)
        print("""
        COEXISTENCE: \(kinds.count) segments, \(totalBytes) bytes, grid \(size.cols)x\(size.rows), \
        \(cellsCompared) cells compared, address sanitizer \(Self.addressSanitizerIsOn ? "ON" : "OFF"), \
        grapheme clustering \(host.graphemeClustering ? "ON" : "OFF"), \
        libghostty \(GhosttySurfaceHost.libraryVersion())
        """)
    }

    // MARK: - Reading the surface

    /// The surface's grid once it has stopped moving. A new surface is created
    /// against a placeholder frame and takes the window's on a later layout pass,
    /// and bytes written before that would be reflowed by the resize.
    private func settledSize(of id: String, in host: GhosttySurfaceHost) async throws -> TerminalSize {
        var last: TerminalSize?
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let current = host.size(id: id)
            if current != last {
                last = current
                stableSince = Date()
            } else if let current, Date().timeIntervalSince(stableSince) > 1 {
                return current
            }
        }
        throw CoexistenceError.surfaceNeverSettled
    }

    /// The visible grid once the surface has shown `marker`, which is the last
    /// thing a segment prints, and two reads in a row agree.
    private func rows(of id: String, in host: GhosttySurfaceHost, endingWith marker: String) async throws -> [String] {
        let grid = try #require(host.size(id: id))
        var previous: [String]?
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            guard let read = host.readText(id: id, maxLines: grid.rows) else { continue }
            let rows = Self.normalised(read)
            if rows.contains(where: { $0.contains(marker) }), rows == previous { return rows }
            previous = rows
        }
        throw CoexistenceError.markerNeverShown(marker)
    }

    /// Trailing spaces and trailing blank rows are not content in either reading,
    /// and the two libraries need not agree on how many of them to report.
    private static func normalised(_ rows: [String]) -> [String] {
        var rows = rows.map { row -> String in
            var row = row
            while row.hasSuffix(" ") { row.removeLast() }
            return row
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    private static func firstDifference(surface: [String], vt: [String]) -> String {
        let count = max(surface.count, vt.count)
        let differing = (0..<count).filter { index in
            (index < surface.count ? surface[index] : nil) != (index < vt.count ? vt[index] : nil)
        }
        guard let first = differing.first else { return "no differing line" }
        return """
        \(differing.count) of \(count) lines differ (surface \(surface.count), vt \(vt.count)). First at line \(first):
          surface: \((first < surface.count ? surface[first] : "<none>").debugDescription)
          vt:      \((first < vt.count ? vt[first] : "<none>").debugDescription)
        """
    }

    /// Whether this process was built with the address sanitizer, read from the
    /// runtime rather than assumed from how the run was started.
    private static var addressSanitizerIsOn: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") != nil
    }
}

/// Outside the suite, because a suite's own traits cannot refer to its members.
enum CoexistenceCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_COEXISTENCE_CHECK"] == "1"
    }

    /// Whether the run is the one with grapheme clustering turned off in the
    /// surface's configuration.
    static var legacyGraphemes: Bool {
        ProcessInfo.processInfo.environment["WIETTY_COEXISTENCE_GRAPHEME"] == "legacy"
    }
}

private enum CoexistenceError: Error {
    case surfaceNeverSettled
    case markerNeverShown(String)
}

/// A deterministic stream of terminal output, in segments that each exercise one
/// kind of thing a program does to a screen.
///
/// Nothing in it asks the terminal a question. A query would be answered by the
/// surface into its own pty, where nothing is reading, and never by the vt
/// terminal, so it would only add bytes that mean nothing to the comparison.
private struct CoexistenceStream {
    enum Kind: String, CaseIterable {
        /// Coloured log lines, the common case.
        case log
        /// Lines far wider than the grid, with tabs, so wrapping carries the load.
        case wrapping
        /// Accents, CJK, box drawing and emoji, placed so wide cells meet the margin.
        case unicode
        /// Cursor addressed painting with erases, the way a full screen program draws.
        case painting
        /// Scrolling regions, inserted and deleted lines and characters, origin mode.
        case regions
        /// The alternate screen, entered and left, ending inside it.
        case alternateScreen
        /// Everything above interleaved, leaving the alternate screen first.
        case mixed
        /// A full reset in the middle of output, the way `reset` sends one, then
        /// the multi code point emoji again. A mode the two libraries restore
        /// differently on reset shows here and nowhere else.
        case reset
        /// Emoji built from several code points: joiners, variation selectors,
        /// skin tones, flags, and combining marks. This is the segment that caught
        /// a bare vt terminal starting without grapheme clustering (mode 2027)
        /// while a surface starts with it; `GhosttyVtTerminal` now sets it.
        case graphemes
        /// Plain lines again, so the last comparison is of an ordinary screen.
        case plain
    }

    let size: TerminalSize
    private var state: UInt64

    init(size: TerminalSize, seed: UInt64) {
        self.size = size
        self.state = seed
    }

    /// Roughly this many bytes per segment, so ten of them pass four megabytes.
    private static let segmentBytes = 520_000
    private static let esc = "\u{1b}"

    // SplitMix64. Seeded, so a failure is the same failure on the next run.
    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    private mutating func pick<T>(_ items: [T]) -> T {
        items[int(0...(items.count - 1))]
    }

    /// Chunk sizes that add up to `count`, from one byte to 64 KiB, so sequences
    /// and multibyte characters are split across writes all over the place.
    mutating func chunkSizes(for count: Int) -> [Int] {
        var sizes: [Int] = []
        var remaining = count
        while remaining > 0 {
            let limit = pick([1, 7, 64, 1_024, 4_096, 65_536])
            let chunk = min(int(1...limit), remaining)
            sizes.append(chunk)
            remaining -= chunk
        }
        return sizes
    }

    mutating func segment(_ kind: Kind, marker: String) -> [UInt8] {
        var out = ""
        out.reserveCapacity(Self.segmentBytes + 4_096)
        switch kind {
        case .log:
            // A full reset first, so whatever the child's login printed is gone
            // from the surface and both terminals start from the same state.
            out += "\(Self.esc)c"
            while out.utf8.count < Self.segmentBytes { out += logLine() }
        case .wrapping:
            while out.utf8.count < Self.segmentBytes { out += wrappingLine() }
        case .unicode:
            while out.utf8.count < Self.segmentBytes { out += unicodeLine() }
        case .painting:
            out += "\(Self.esc)[2J\(Self.esc)[H"
            while out.utf8.count < Self.segmentBytes { out += paintOperation() }
            out += "\(Self.esc)[0m"
        case .regions:
            while out.utf8.count < Self.segmentBytes { out += regionOperation() }
            out += "\(Self.esc)[r\(Self.esc)[?6l\(Self.esc)[?7h\(Self.esc)[0m\(Self.esc)[\(size.rows);1H"
        case .alternateScreen:
            while out.utf8.count < Self.segmentBytes {
                out += "\(Self.esc)[?1049h\(Self.esc)[2J\(Self.esc)[H"
                for _ in 0..<400 { out += paintOperation() }
                out += "\(Self.esc)[0m\(Self.esc)[?1049l"
                for _ in 0..<20 { out += logLine() }
            }
            out += "\(Self.esc)[?1049h\(Self.esc)[2J\(Self.esc)[H"
            for _ in 0..<400 { out += paintOperation() }
            out += "\(Self.esc)[0m\(Self.esc)[\(size.rows / 2);1H"
        case .mixed:
            out += "\(Self.esc)[?1049l"
            while out.utf8.count < Self.segmentBytes {
                switch int(0...5) {
                case 0: for _ in 0..<30 { out += logLine() }
                case 1: for _ in 0..<5 { out += wrappingLine() }
                case 2: for _ in 0..<10 { out += unicodeLine() }
                case 3: for _ in 0..<60 { out += paintOperation() }
                case 4:
                    for _ in 0..<40 { out += regionOperation() }
                    out += "\(Self.esc)[r\(Self.esc)[?6l\(Self.esc)[?7h\(Self.esc)[0m"
                default:
                    out += "\(Self.esc)[?1049h\(Self.esc)[2J"
                    for _ in 0..<40 { out += paintOperation() }
                    out += "\(Self.esc)[0m\(Self.esc)[?1049l"
                }
            }
            out += "\(Self.esc)[0m\(Self.esc)[\(size.rows);1H"
        case .graphemes:
            while out.utf8.count < Self.segmentBytes { out += graphemeLine() }
        case .reset:
            while out.utf8.count < Self.segmentBytes {
                for _ in 0..<40 { out += logLine() }
                out += "\(Self.esc)[?2004h\(Self.esc)[?7l\(Self.esc)[5;20r\(Self.esc)[1;35m"
                out += "\(Self.esc)c"
                for _ in 0..<40 { out += graphemeLine() }
                for _ in 0..<10 { out += wrappingLine() }
            }
        case .plain:
            var line = 0
            while out.utf8.count < Self.segmentBytes {
                line += 1
                out += "plain line \(line) \(words(int(2...14)))\r\n"
            }
        }
        out += "\r\n\(marker)"
        return Array(out.utf8)
    }

    // MARK: - Pieces

    private static let vocabulary = [
        "build", "linking", "compiled", "warning", "target", "module", "cache", "resolved",
        "request", "connection", "timeout", "retry", "payload", "session", "terminal", "stream",
        "frame", "viewport", "scrollback", "cursor", "the", "of", "in", "for", "ok", "done",
    ]

    private mutating func words(_ count: Int) -> String {
        (0..<count).map { _ in pick(Self.vocabulary) }.joined(separator: " ")
    }

    private mutating func sgr() -> String {
        switch int(0...9) {
        case 0: return "\(Self.esc)[0m"
        case 1: return "\(Self.esc)[1m"
        case 2: return "\(Self.esc)[\(pick([2, 3, 4, 7, 9]))m"
        case 3: return "\(Self.esc)[3\(int(0...7))m"
        case 4: return "\(Self.esc)[9\(int(0...7))m"
        case 5: return "\(Self.esc)[4\(int(0...7))m"
        case 6: return "\(Self.esc)[38;5;\(int(0...255))m"
        case 7: return "\(Self.esc)[48;5;\(int(0...255))m"
        case 8: return "\(Self.esc)[38;2;\(int(0...255));\(int(0...255));\(int(0...255))m"
        default: return "\(Self.esc)[1;4;3\(int(0...7));4\(int(0...7))m"
        }
    }

    private mutating func logLine() -> String {
        let level = pick(["\(Self.esc)[32mINFO", "\(Self.esc)[33mWARN", "\(Self.esc)[1;31mERROR", "\(Self.esc)[36mDEBUG"])
        let stamp = "2026-11-22 14:\(int(10...59)):\(int(10...59))"
        return "\(Self.esc)[2m\(stamp)\(Self.esc)[0m \(level)\(Self.esc)[0m \(words(int(3...22)))\r\n"
    }

    private mutating func wrappingLine() -> String {
        var line = ""
        let target = int(150...900)
        while line.count < target {
            line += pick(Self.vocabulary)
            line += int(0...6) == 0 ? "\t" : " "
            if int(0...9) == 0 { line += sgr() }
        }
        return line + "\(Self.esc)[0m\r\n"
    }

    private static let unicodePieces = [
        "héllo wörld", "naïve café", "日本語のテキスト", "한국어 텍스트", "中文字符", "┌──┬──┐", "│  │  │", "└──┴──┘",
        "→ ← ↑ ↓", "😀", "🚀", "✅", "▁▂▃▄▅▆▇█", "Ω≈ç√∫", "ｆｕｌｌｗｉｄｔｈ", "abc",
    ]

    private mutating func unicodeLine() -> String {
        var line = String(repeating: " ", count: int(0...6))
        for _ in 0..<int(1...14) {
            if int(0...5) == 0 { line += sgr() }
            line += pick(Self.unicodePieces)
            line += pick(["", " ", "  "])
        }
        return line + "\(Self.esc)[0m\r\n"
    }

    private mutating func paintOperation() -> String {
        let row = int(1...size.rows)
        let col = int(1...size.cols)
        switch int(0...19) {
        case 0...9: return "\(Self.esc)[\(row);\(col)H\(sgr())\(pick(Self.vocabulary))"
        case 10: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(pick([0, 1, 2]))K"
        case 11: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(int(1...12))X"
        case 12: return "\(Self.esc)[\(int(1...4))\(pick(["A", "B", "C", "D"]))\(pick(Self.vocabulary))"
        case 13: return "\(Self.esc)7\(Self.esc)[\(row);\(col)H\(pick(Self.unicodePieces))\(Self.esc)8"
        case 14: return "\(Self.esc)[\(row);\(col)H\t\(pick(Self.vocabulary))\u{8}\u{8}x"
        case 15: return "\(Self.esc)[\(row);\(col)H\(pick(["\(Self.esc)M", "\(Self.esc)D", "\(Self.esc)E", "\r", "\n"]))"
        case 16: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(pick([0, 1]))J"
        case 17: return "\(Self.esc)[\(row);\(max(size.cols - 3, 1))H\(sgr())\(words(2))"
        case 18: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(int(2...9))b"
        default: return "\(Self.esc)[\(row);\(col)H\(sgr())\(pick(Self.unicodePieces))"
        }
    }

    private mutating func regionOperation() -> String {
        let top = int(1...max(size.rows - 2, 1))
        let bottom = int(min(top + 1, size.rows)...size.rows)
        let row = int(1...size.rows)
        let col = int(1...size.cols)
        switch int(0...13) {
        case 0: return "\(Self.esc)[\(top);\(bottom)r"
        case 1: return "\(Self.esc)[r"
        case 2: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(int(1...5))L"
        case 3: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(int(1...5))M"
        case 4: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(int(1...9))@"
        case 5: return "\(Self.esc)[\(row);\(col)H\(Self.esc)[\(int(1...9))P"
        case 6: return "\(Self.esc)[\(int(1...4))S"
        case 7: return "\(Self.esc)[\(int(1...4))T"
        case 8: return "\(Self.esc)[?6\(pick(["h", "l"]))"
        case 9: return "\(Self.esc)[?7\(pick(["h", "l"]))\(Self.esc)[\(row);\(max(size.cols - 6, 1))H\(words(3))"
        case 10: return "\(Self.esc)[\(row);\(col)H\(sgr())\(words(int(1...6)))\r\n"
        case 11: return "\(sgr())\(words(int(1...12)))\n"
        case 12: return "\(Self.esc)[\(row);\(col)H\(Self.esc)M\(Self.esc)M\(pick(Self.unicodePieces))"
        default: return "\r\n\(words(int(1...4)))"
        }
    }

    private static let graphemePieces = [
        "👨‍👩‍👧‍👦", "👩‍💻", "🏳️‍🌈", "❤️", "☀️", "👍🏽", "🧑🏿‍🚀", "🇳🇱", "🇯🇵", "e\u{301}", "a\u{308}\u{304}", "क्षि", "1️⃣", "✈︎",
    ]

    private mutating func graphemeLine() -> String {
        var line = String(repeating: " ", count: int(0...4))
        for _ in 0..<int(1...12) {
            line += pick(Self.graphemePieces)
            line += pick(["", " ", "x", " ok "])
        }
        return line + "\r\n"
    }
}
