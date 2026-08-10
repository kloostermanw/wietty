import Testing
import Foundation
@testable import Wietty

/// The composition state behind `NSTextInputClient`.
///
/// The rest of IME handling needs a first responder in a real window with a live
/// input method attached, so this is the part CI can hold: what AppKit is told
/// about the marked text, and what a range it proposes is clamped to.
@Suite struct GhosttyMarkedTextTests {
    @Test func nothingIsComposedToStartWith() {
        let marked = GhosttyMarkedText()
        #expect(marked.isComposing == false)
        #expect(marked.markedRange.location == NSNotFound)
        #expect(marked.selectedRange.location == NSNotFound)
    }

    @Test func settingTextStartsAComposition() {
        var marked = GhosttyMarkedText()
        marked.set("に", selection: NSRange(location: 1, length: 0))
        #expect(marked.isComposing)
        #expect(marked.text == "に")
        #expect(marked.markedRange == NSRange(location: 0, length: 1))
        #expect(marked.selectedRange == NSRange(location: 1, length: 0))
    }

    /// An input method clearing its composition sends an empty string, and
    /// composing nothing is not composing. Reporting a marked range of length zero
    /// instead leaves AppKit drawing a candidate window over an empty preedit.
    @Test func emptyTextIsNotAComposition() {
        var marked = GhosttyMarkedText()
        marked.set("", selection: NSRange(location: 0, length: 0))
        #expect(marked.isComposing == false)
        #expect(marked.markedRange.location == NSNotFound)
    }

    /// Lengths are in UTF-16 units because that is what `NSRange` means to AppKit.
    /// Counting characters would put the candidate window in the wrong place for
    /// anything outside the basic plane.
    @Test func lengthIsCountedInUTF16Units() {
        var marked = GhosttyMarkedText()
        marked.set("🇯🇵", selection: NSRange(location: 0, length: 0))
        #expect(marked.length == 4)
        #expect(marked.markedRange == NSRange(location: 0, length: 4))
    }

    /// An input method can report a selection from the string it was about to set
    /// rather than the one it did, so the range is clamped rather than trusted.
    @Test func aSelectionPastTheEndIsClamped() {
        var marked = GhosttyMarkedText()
        marked.set("ab", selection: NSRange(location: 9, length: 4))
        #expect(marked.selectedRange == NSRange(location: 2, length: 0))
    }

    /// A range that ends before the composition starts collapses to the start of
    /// it rather than being stretched into one that overlaps: its end is clamped
    /// against its own clamped start, so the length cannot grow.
    @Test func aRangeEntirelyBeforeTheCompositionCollapses() {
        var marked = GhosttyMarkedText()
        marked.set("ab", selection: NSRange(location: -3, length: 1))
        #expect(marked.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test func aNegativeStartInsideTheCompositionKeepsWhatItCovers() {
        var marked = GhosttyMarkedText()
        marked.set("ab", selection: NSRange(location: -1, length: 2))
        #expect(marked.selectedRange == NSRange(location: 0, length: 1))
    }

    @Test func clearingEndsTheComposition() {
        var marked = GhosttyMarkedText()
        marked.set("に", selection: NSRange(location: 1, length: 0))
        marked.clear()
        #expect(marked.isComposing == false)
        #expect(marked.length == 0)
        #expect(marked.selectedRange.location == NSNotFound)
    }

    @Test func aSubstringInsideTheCompositionComesBack() {
        var marked = GhosttyMarkedText()
        marked.set("にほん", selection: NSRange(location: 3, length: 0))
        #expect(marked.substring(in: NSRange(location: 1, length: 2)) == "ほん")
    }

    /// Outside the composition is nil rather than an empty string: AppKit reads
    /// nil as "there is no such text" and an empty string as "that text is empty".
    @Test func aSubstringOutsideTheCompositionIsNil() {
        var marked = GhosttyMarkedText()
        marked.set("ab", selection: NSRange(location: 2, length: 0))
        #expect(marked.substring(in: NSRange(location: 1, length: 8)) == nil)
    }

    @Test func aProposedRangeIsClampedToTheComposition() {
        var marked = GhosttyMarkedText()
        marked.set("abc", selection: NSRange(location: 3, length: 0))
        #expect(marked.clamped(NSRange(location: 2, length: 9)) == NSRange(location: 2, length: 1))
        #expect(marked.clamped(NSRange(location: 9, length: 1)) == NSRange(location: 3, length: 0))
    }
}
