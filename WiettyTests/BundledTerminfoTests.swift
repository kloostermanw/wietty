import Testing
import Foundation
@testable import Wietty

/// The terminfo the app ships and the environment it hands a child.
///
/// The bundle lookup itself needs a built app bundle, so what is asserted here is
/// the logic around it: which TERM each state names, how TERMINFO_DIRS is composed
/// so the bundled entry adds to the child's databases rather than hiding them, and
/// that the compiled entry is recognised under either layout tic may write.
struct BundledTerminfoTests {
    private let dir = URL(fileURLWithPath: "/Applications/Wietty.app/Contents/Resources/terminfo")

    @Test func termIsGhosttyOnlyWhenTheEntryIsBundled() {
        #expect(BundledTerminfo.term(bundled: true) == "xterm-ghostty")
        // The fallback every macOS terminfo database carries, so a build without
        // the entry does not name one the shell cannot resolve.
        #expect(BundledTerminfo.term(bundled: false) == "xterm-256color")
    }

    @Test func terminfoDirsIsNilWhenNothingIsBundled() {
        // Nil leaves the caller's own value untouched, pairing with the fallback TERM.
        #expect(BundledTerminfo.terminfoDirs(directory: nil, inheriting: nil) == nil)
        #expect(BundledTerminfo.terminfoDirs(directory: nil, inheriting: "/x") == nil)
    }

    @Test func terminfoDirsKeepsDefaultDatabasesWhenNothingIsInherited() {
        // The trailing separator is load bearing: it is how ncurses is told to keep
        // its compiled in default search path, so every other TERM still resolves.
        #expect(BundledTerminfo.terminfoDirs(directory: dir, inheriting: nil) == "\(dir.path):")
        #expect(BundledTerminfo.terminfoDirs(directory: dir, inheriting: "") == "\(dir.path):")
    }

    @Test func terminfoDirsPrependsToAnInheritedValue() {
        // Prepended so the bundled entry wins, and the inherited databases are kept.
        #expect(BundledTerminfo.terminfoDirs(directory: dir, inheriting: "/usr/share/terminfo")
                == "\(dir.path):/usr/share/terminfo")
    }

    @Test func entryIsFoundUnderTheHexLayout() {
        // tic on macOS writes xterm-ghostty under a hex directory (78 is 'x').
        #expect(BundledTerminfo.hasEntry(in: dir) { $0 == dir.appendingPathComponent("78/xterm-ghostty").path })
    }

    @Test func entryIsFoundUnderTheLetterLayout() {
        // A tic that writes single letter directories is accepted too.
        #expect(BundledTerminfo.hasEntry(in: dir) { $0 == dir.appendingPathComponent("x/xterm-ghostty").path })
    }

    @Test func missingEntryIsNotMistakenForABundledOne() {
        // An empty or wrong directory must resolve to no bundled entry, so TERM
        // falls back rather than naming an entry that is not there.
        #expect(!BundledTerminfo.hasEntry(in: dir) { _ in false })
    }
}
