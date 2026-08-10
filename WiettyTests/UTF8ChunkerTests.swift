import Testing
@testable import Wietty

@Suite struct UTF8ChunkerTests {
    @Test func passesAsciiThrough() {
        var chunker = UTF8Chunker()
        #expect(chunker.take(Array("hello".utf8)) == "hello")
    }

    @Test func holdsBackSplitMultibyteUntilComplete() {
        var chunker = UTF8Chunker()
        // "é" is 0xC3 0xA9, arriving in two separate notifications.
        #expect(chunker.take([0x61, 0xC3]) == "a")
        #expect(chunker.take([0xA9]) == "é")
    }

    @Test func holdsBackThreeByteSequenceAcrossThreeCalls() {
        var chunker = UTF8Chunker()
        // "➜" is 0xE2 0x9E 0x9C.
        #expect(chunker.take([0xE2]) == "")
        #expect(chunker.take([0x9E]) == "")
        #expect(chunker.take([0x9C]) == "➜")
    }

    @Test func substitutesInvalidLeadByteRatherThanStalling() {
        var chunker = UTF8Chunker()
        // 0xFF is never a valid lead byte. It must not wedge the pane.
        #expect(chunker.take([0xFF, 0x61]) == "\u{FFFD}a")
    }

    @Test func substitutesTruncatedSequenceWhenContinuationIsWrong() {
        var chunker = UTF8Chunker()
        // 0xE2 promises two continuation bytes; 0x41 is not one.
        #expect(chunker.take([0xE2, 0x9E, 0x41]) == "\u{FFFD}A")
    }

    @Test func emitsNothingForEmptyInput() {
        var chunker = UTF8Chunker()
        #expect(chunker.take([]) == "")
    }

    @Test func skipsMultipleContinuationBytesInFailedSequence() {
        var chunker = UTF8Chunker()
        // 0xF0 promises three continuation bytes; 0x9F and 0x98 are valid continuation bytes
        // but 0x21 ('!') is not, so all three should be skipped in the failure path.
        #expect(chunker.take([0xF0, 0x9F, 0x98, 0x21]) == "\u{FFFD}!")
    }

    @Test func validSequenceAfterInvalidSequence() {
        var chunker = UTF8Chunker()
        // 0xE2 0x9E 0x41 is invalid (third byte is ASCII, not continuation).
        // 0xC3 0xA9 is valid UTF-8 for "é". The invalid sequence should emit one U+FFFD,
        // not prevent the next sequence from decoding.
        #expect(chunker.take([0xE2, 0x9E, 0x41, 0xC3, 0xA9]) == "\u{FFFD}Aé")
    }
}
