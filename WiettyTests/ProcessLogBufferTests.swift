import Testing
@testable import Wietty

@Suite struct ProcessLogBufferTests {
    @Test func stripsAnsiEscapeSequences() {
        #expect(stripANSI("\u{1B}[31mred\u{1B}[0m") == "red")
        #expect(stripANSI("plain") == "plain")
        #expect(stripANSI("\u{1B}[2J\u{1B}[Hcleared") == "cleared")
    }

    @Test func splitsChunksIntoLines() {
        var buffer = ProcessLogBuffer(limit: 100)
        buffer.append("one\ntwo\n")
        buffer.append("three")
        #expect(buffer.lines == ["one", "two", "three"])
    }

    @Test func appendsToOpenTrailingLine() {
        var buffer = ProcessLogBuffer(limit: 100)
        buffer.append("par")
        buffer.append("tial\ndone\n")
        #expect(buffer.lines == ["partial", "done"])
    }

    @Test func capsAtLimitKeepingMostRecent() {
        var buffer = ProcessLogBuffer(limit: 3)
        buffer.append("1\n2\n3\n4\n5\n")
        #expect(buffer.lines == ["3", "4", "5"])
    }

    @Test func stripsAnsiOnAppendAndClears() {
        var buffer = ProcessLogBuffer(limit: 10)
        buffer.append("\u{1B}[32mok\u{1B}[0m\n")
        #expect(buffer.lines == ["ok"])
        buffer.clear()
        #expect(buffer.lines == [])
    }

    @Test func carriageReturnOverwritesFromLineStart() {
        var buffer = ProcessLogBuffer(limit: 100)
        buffer.append("aaaa\rbb")
        #expect(buffer.lines == ["bbaa"])
    }

    @Test func carriageReturnRewritesProgressLineInPlace() {
        var buffer = ProcessLogBuffer(limit: 100)
        buffer.append("progress 10%\rprogress 20%\rprogress 30%")
        #expect(buffer.lines == ["progress 30%"])
    }

    @Test func carriageReturnCollapsesAcrossChunks() {
        var buffer = ProcessLogBuffer(limit: 100)
        buffer.append("10%\r")
        buffer.append("20%\n")
        #expect(buffer.lines == ["20%"])
    }

    @Test func progressBarDoesNotGrowUnbounded() {
        var buffer = ProcessLogBuffer(limit: 100, lineLimit: 64)
        for i in 0..<1000 { buffer.append("\rprogress \(i)%") }
        #expect(buffer.lines.count == 1)
        #expect((buffer.lines.first?.count ?? 0) <= 64)
    }

    @Test func capsLineLengthKeepingMostRecentOpenLine() {
        var buffer = ProcessLogBuffer(limit: 100, lineLimit: 5)
        buffer.append("abcdefgh")
        #expect(buffer.lines == ["defgh"])
    }

    @Test func capsLineLengthOnCompletedLine() {
        var buffer = ProcessLogBuffer(limit: 100, lineLimit: 5)
        buffer.append("abcdefgh\n")
        #expect(buffer.lines == ["defgh"])
    }
}
