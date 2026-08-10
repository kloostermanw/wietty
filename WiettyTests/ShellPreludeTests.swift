import Testing
import Foundation
@testable import Wietty

@Suite struct ShellPreludeTests {
    @Test func noLinesLeavesTheCommandByteIdentical() {
        #expect(ShellPrelude.script(lines: [], command: "npm run dev") == "npm run dev")
    }

    @Test func prependsASingleLineBeforeTheCommand() {
        let script = ShellPrelude.script(lines: ["export EDITOR='vim'"], command: "npm run dev")
        #expect(script == "export EDITOR='vim'\nnpm run dev")
    }

    @Test func keepsLineOrderAndSeparatesWithNewlines() {
        let script = ShellPrelude.script(
            lines: ["export PATH=$HOME/bin:$PATH", "source ~/bin/env.sh"],
            command: "fork"
        )
        #expect(script == "export PATH=$HOME/bin:$PATH\nsource ~/bin/env.sh\nfork")
    }

    @Test func blankLinesAreDroppedSoAStrayEntryCannotEmptyTheScript() {
        let script = ShellPrelude.script(lines: ["", "   ", "export A=1"], command: "fork")
        #expect(script == "export A=1\nfork")
    }

    @Test func onlyBlankLinesLeavesTheCommandUnchanged() {
        #expect(ShellPrelude.script(lines: ["", "  "], command: "fork") == "fork")
    }

    @Test func aMultiLineEntryIsPassedThroughAsWritten() {
        let script = ShellPrelude.script(lines: ["if [ -f .env ]; then\n  source .env\nfi"], command: "fork")
        #expect(script == "if [ -f .env ]; then\n  source .env\nfi\nfork")
    }
}
