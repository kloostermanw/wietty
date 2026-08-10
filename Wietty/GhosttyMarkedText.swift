import Foundation

/// The in-progress composition an input method is building, as `NSTextInputClient`
/// describes it.
///
/// Exists as its own type for two reasons. It is the only part of IME handling
/// that is pure state rather than AppKit plumbing, so it is the only part that can
/// be asserted in CI: everything else needs a first responder in a real window and
/// a live surface. And the ranges it answers are the ones AppKit uses to place the
/// candidate window, so getting them wrong shows up as a floating palette in the
/// wrong corner of the screen rather than as a crash.
///
/// Ranges are in UTF-16 units, because that is what `NSRange` means to AppKit. The
/// document is the marked text and nothing else: a terminal has no editable buffer
/// behind the composition, so position zero is the start of the preedit rather than
/// the start of any line.
struct GhosttyMarkedText: Equatable {
    /// The text being composed, or nil when nothing is. Empty is normalised to
    /// nil, because an input method clearing its composition sends an empty
    /// string and "composing nothing" is not composing.
    private(set) var text: String?
    private(set) var selection = NSRange(location: 0, length: 0)

    var isComposing: Bool { !(text ?? "").isEmpty }

    /// The length of the composition in UTF-16 units.
    var length: Int { text?.utf16.count ?? 0 }

    /// What AppKit asks for to decide whether to draw a candidate window at all.
    /// `NSNotFound` means "no marked text", which is not the same as an empty
    /// range at zero.
    var markedRange: NSRange {
        isComposing ? NSRange(location: 0, length: length) : NSRange(location: NSNotFound, length: 0)
    }

    /// The insertion point inside the composition, or `NSNotFound` when there is
    /// no composition to have one.
    var selectedRange: NSRange {
        isComposing ? selection : NSRange(location: NSNotFound, length: 0)
    }

    /// Replaces the composition. The selection is clamped to what the new text
    /// actually has, because an input method can report a range from the string
    /// it was about to set rather than the one it did.
    mutating func set(_ text: String?, selection: NSRange) {
        let normalized = text.flatMap { $0.isEmpty ? nil : $0 }
        self.text = normalized
        let length = normalized?.utf16.count ?? 0
        let location = min(max(selection.location, 0), length)
        let end = min(max(selection.location + selection.length, location), length)
        self.selection = NSRange(location: location, length: end - location)
    }

    mutating func clear() {
        text = nil
        selection = NSRange(location: 0, length: 0)
    }

    /// The composition's text in `range`, or nil when there is no composition or the
    /// range is not inside it. The one caller, `attributedSubstring`, answers nil to
    /// AppKit for a document it has nothing to say about, so there is no case here
    /// for a range against an absent composition.
    func substring(in range: NSRange) -> String? {
        guard let text else { return nil }
        let string = text as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= string.length else { return nil }
        return string.substring(with: range)
    }

    /// `range`, brought inside the composition. AppKit asks for ranges it has not
    /// checked against the current document, so a proposed range is a request
    /// rather than a fact.
    func clamped(_ range: NSRange) -> NSRange {
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)
        return NSRange(location: location, length: end - location)
    }
}
