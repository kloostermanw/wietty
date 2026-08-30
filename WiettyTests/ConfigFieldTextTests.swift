import Testing
import Foundation
@testable import Wietty

/// The Edit workspace page edits array fields and the `env` map as free text. These
/// pin the parsing so a blank line never becomes an entry and a value that contains
/// `=` survives.
@Suite struct ConfigFieldTextTests {
    @Test func linesDropBlanksAndTrim() {
        let text = "export PATH=$HOME/bin:$PATH\n\n  \n source ~/env.sh "
        #expect(ConfigFieldText.toLines(text) == ["export PATH=$HOME/bin:$PATH", "source ~/env.sh"])
    }

    @Test func linesRoundTrip() {
        let lines = ["a", "b", "c"]
        #expect(ConfigFieldText.toLines(ConfigFieldText.fromLines(lines)) == lines)
    }

    @Test func envParsesKeyValuePairs() {
        let env = ConfigFieldText.toEnv("FOO=bar\nBAZ=qux")
        #expect(env == ["FOO": "bar", "BAZ": "qux"])
    }

    /// The value keeps everything after the first `=`.
    @Test func envKeepsEqualsInsideValue() {
        #expect(ConfigFieldText.toEnv("URL=a=b=c") == ["URL": "a=b=c"])
    }

    @Test func envSkipsLinesWithNoKey() {
        #expect(ConfigFieldText.toEnv("nokey\n=value\nFOO=bar") == ["FOO": "bar"])
    }

    /// Sorted so the text does not reshuffle between reads of the same map.
    @Test func envFormatsSortedByKey() {
        #expect(ConfigFieldText.fromEnv(["B": "2", "A": "1"]) == "A=1\nB=2")
    }
}
