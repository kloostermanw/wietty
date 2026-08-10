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
}
