import Testing
@testable import Wietty

@Suite struct OSCStringTrackerTests {
    @Test func countsABareBel() {
        var tracker = OSCStringTracker()
        #expect(tracker.bells(in: [0x07]) == 1)
    }

    @Test func ignoresTheBelThatTerminatesAnOscString() {
        var tracker = OSCStringTracker()
        // ESC ] 0 ; x BEL, an ordinary window title update.
        #expect(tracker.bells(in: [0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x07]) == 0)
    }

    @Test func ignoresThePromptMarkerShellsEmitEveryPrompt() {
        var tracker = OSCStringTracker()
        // ESC ] 133 ; A BEL
        #expect(tracker.bells(in: Array("\u{1B}]133;A\u{07}".utf8)) == 0)
    }

    @Test func ignoresABelInAnOscStringSplitAcrossCalls() {
        var tracker = OSCStringTracker()
        #expect(tracker.bells(in: Array("\u{1B}]0;ti".utf8)) == 0)
        #expect(tracker.bells(in: Array("tle\u{07}".utf8)) == 0)
    }

    @Test func countsABelAfterAnOscStringEndedWithST() {
        var tracker = OSCStringTracker()
        // ESC ] 0 ; x ESC \  then a real BEL
        #expect(tracker.bells(in: Array("\u{1B}]0;x\u{1B}\\\u{07}".utf8)) == 1)
    }

    @Test func countsMultipleBellsInOneChunk() {
        var tracker = OSCStringTracker()
        #expect(tracker.bells(in: [0x07, 0x41, 0x07]) == 2)
    }

    @Test func returnsToGroundAfterANonStringEscapeSequence() {
        var tracker = OSCStringTracker()
        // ESC [ 1 m is SGR, not a string; a following BEL is real.
        #expect(tracker.bells(in: Array("\u{1B}[1m\u{07}".utf8)) == 1)
    }

    @Test func countsABellArrivingImmediatelyAfterABareEscape() {
        var tracker = OSCStringTracker()
        #expect(tracker.bells(in: [0x1B, 0x07]) == 1)
    }

    @Test func countsABellAfterADoubledEscape() {
        var tracker = OSCStringTracker()
        #expect(tracker.bells(in: [0x1B, 0x1B, 0x07]) == 1)
    }

    @Test func ignoresABellThatTerminatesAStringAfterANonSTEscape() {
        var tracker = OSCStringTracker()
        // ESC ] 0 ; a ESC BEL: the ESC is not ST, the string stays open, and
        // BEL terminates it rather than ringing.
        #expect(tracker.bells(in: Array("\u{1B}]0;a\u{1B}\u{07}".utf8)) == 0)
    }
}
