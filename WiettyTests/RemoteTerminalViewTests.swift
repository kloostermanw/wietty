import Testing
@testable import Wietty

/// A refusal's message comes from the other Mac and is written into this Mac's
/// terminal, so it must not be able to drive that terminal.
@Suite struct RemoteTerminalViewTests {
    @Test func anEscapeSequenceInARefusalComesOutAsPlainText() {
        #expect(RemoteTerminalView.printable("bad\u{1B}[2Jtoken\u{1B}]0;title\u{07}")
                == "bad[2Jtoken]0;title")
    }

    @Test func controlCharactersOfEveryRangeAreDropped() {
        #expect(RemoteTerminalView.printable("a\u{0}\r\n\u{7F}b\u{80}\u{9B}31mc\u{9F}")
                == "ab31mc")
    }

    @Test func ordinaryTextIsKept() {
        #expect(RemoteTerminalView.printable("Sessie é ✓ ¡ok!") == "Sessie é ✓ ¡ok!")
    }
}
