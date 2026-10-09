import Testing
import Foundation
@testable import Wietty

/// The body of one `OSC 7501` report, after `7501;` and before the terminator.
///
/// Every base64 value here was produced by `printf '%s' … | base64`, not by the
/// code under test, so a decoder that is wrong cannot also be the thing that wrote
/// the expectation.
@Suite struct ProgramStatusReportTests {
    // MARK: - What a report sets

    @Test func aBareStateAddressesTheRootRecord() {
        #expect(ProgramStatusReport.parse("state=working")
                == .set(id: nil, ProgramStatusRecord(state: .working)))
    }

    @Test func everyKeyIsCarriedIntoTheRecord() {
        // Terraform's example from the spec, with the message spelled in full.
        let report = ProgramStatusReport.parse(
            "state=blocked:kind=permission:app=terraform:progress=40:title=aGk=:msg=QXBwcm92ZSB0aGUgYXBwbHk/")
        #expect(report == .set(id: nil, ProgramStatusRecord(
            state: .blocked, kind: .permission, progress: 40, app: "terraform",
            title: "hi", msg: "Approve the apply?")))
    }

    @Test func anIdAddressesThatRecord() {
        #expect(ProgramStatusReport.parse("state=done:id=deploy/us-east")
                == .set(id: "deploy/us-east", ProgramStatusRecord(state: .done)))
    }

    @Test func clearWithoutAnIdClearsEverything() {
        #expect(ProgramStatusReport.parse("state=clear") == .clear(id: nil))
    }

    @Test func clearWithAnIdClearsThatSubtree() {
        #expect(ProgramStatusReport.parse("state=clear:id=us-east") == .clear(id: "us-east"))
    }

    // MARK: - The syntax

    @Test func whitespaceAroundKeysAndValuesIsRemoved() {
        #expect(ProgramStatusReport.parse(" state = done : app = brew ")
                == .set(id: nil, ProgramStatusRecord(state: .done, app: "brew")))
    }

    @Test func theLastValueOfARepeatedKeyWins() {
        #expect(ProgramStatusReport.parse("state=working:state=error")
                == .set(id: nil, ProgramStatusRecord(state: .error)))
    }

    @Test func malformedPairsAreSkippedAndTheRestApplies() {
        // No `=`, an empty key, a key outside [a-z], and a value byte outside the
        // value set: each loses only itself. The bad `app` pairs come after the good
        // one, so either surviving would override it.
        let report = ProgramStatusReport.parse("junk:=x:app=brew:App=other:app=br;ew:state=done")
        #expect(report == .set(id: nil, ProgramStatusRecord(state: .done, app: "brew")))
    }

    @Test func unknownKeysAreIgnored() {
        #expect(ProgramStatusReport.parse("state=idle:colour=red")
                == .set(id: nil, ProgramStatusRecord(state: .idle)))
    }

    // MARK: - Reports that are ignored whole

    @Test func aReportWithNoStateIsIgnored() {
        #expect(ProgramStatusReport.parse("app=brew:msg=aGk=") == nil)
    }

    @Test func anUnknownStateIsIgnoredRatherThanReadAsIdle() {
        #expect(ProgramStatusReport.parse("state=paused:app=brew") == nil)
    }

    @Test func aMalformedIdIgnoresTheReportRatherThanFallingBackToTheRoot() {
        #expect(ProgramStatusReport.parse("state=done:id=a//b") == nil)
        #expect(ProgramStatusReport.parse("state=done:id=") == nil)
        #expect(ProgramStatusReport.parse("state=done:id=a,b") == nil)
        #expect(ProgramStatusReport.parse("state=clear:id=/a") == nil)
    }

    @Test func anIdPastItsLimitsIgnoresTheReport() {
        let segment32 = String(repeating: "s", count: 32)
        #expect(ProgramStatusReport.parse("state=done:id=\(segment32)") != nil)
        #expect(ProgramStatusReport.parse("state=done:id=\(segment32)s") == nil)
        let eightDeep = Array(repeating: "a", count: 8).joined(separator: "/")
        #expect(ProgramStatusReport.parse("state=done:id=\(eightDeep)") != nil)
        #expect(ProgramStatusReport.parse("state=done:id=\(eightDeep)/a") == nil)
        // Four 32 byte segments and their separators come to 131, past 128.
        let long = Array(repeating: segment32, count: 4).joined(separator: "/")
        #expect(ProgramStatusReport.parse("state=done:id=\(long)") == nil)
    }

    @Test func aKeyLongerThanSixteenBytesDiscardsTheReport() {
        let key16 = String(repeating: "k", count: 16)
        #expect(ProgramStatusReport.parse("state=done:\(key16)=1") != nil)
        #expect(ProgramStatusReport.parse("state=done:\(key16)k=1") == nil)
    }

    @Test func anAppPastThirtyTwoBytesDiscardsTheReport() {
        let app32 = String(repeating: "a", count: 32)
        #expect(ProgramStatusReport.parse("state=done:app=\(app32)")
                == .set(id: nil, ProgramStatusRecord(state: .done, app: app32)))
        #expect(ProgramStatusReport.parse("state=done:app=\(app32)a") == nil)
    }

    // MARK: - Values treated as absent

    @Test func anAppOutsideItsCharacterSetIsAbsent() {
        // `,` and `=` pass the pair grammar but not the app grammar.
        #expect(ProgramStatusReport.parse("state=done:app=a,b")
                == .set(id: nil, ProgramStatusRecord(state: .done)))
    }

    @Test func kindIsKeptOnlyOnABlockedRecord() {
        #expect(ProgramStatusReport.parse("state=working:kind=auth")
                == .set(id: nil, ProgramStatusRecord(state: .working)))
        #expect(ProgramStatusReport.parse("state=blocked:kind=question")
                == .set(id: nil, ProgramStatusRecord(state: .blocked, kind: .question)))
    }

    @Test func anUnknownKindIsAbsent() {
        #expect(ProgramStatusReport.parse("state=blocked:kind=coffee")
                == .set(id: nil, ProgramStatusRecord(state: .blocked)))
    }

    @Test func progressIsKeptOnlyWhileWorkingOrBlocked() {
        #expect(ProgramStatusReport.parse("state=blocked:progress=0")
                == .set(id: nil, ProgramStatusRecord(state: .blocked, progress: 0)))
        #expect(ProgramStatusReport.parse("state=done:progress=100")
                == .set(id: nil, ProgramStatusRecord(state: .done)))
    }

    @Test func progressOutOfRangeOrNotAnIntegerIsAbsent() {
        for value in ["101", "-1", "4.5", "", "99999999999999999999999"] {
            #expect(ProgramStatusReport.parse("state=working:progress=\(value)")
                    == .set(id: nil, ProgramStatusRecord(state: .working)), "progress=\(value)")
        }
        #expect(ProgramStatusReport.parse("state=working:progress=100")
                == .set(id: nil, ProgramStatusRecord(state: .working, progress: 100)))
    }

    @Test func anEmptyTextValueIsAbsent() {
        #expect(ProgramStatusReport.parse("state=done:msg=:title=")
                == .set(id: nil, ProgramStatusRecord(state: .done)))
    }

    // MARK: - Free text

    @Test func base64PaddingIsOptional() {
        #expect(ProgramStatusReport.parse("state=done:msg=aGk")
                == .set(id: nil, ProgramStatusRecord(state: .done, msg: "hi")))
        #expect(ProgramStatusReport.parse("state=done:msg=UGhvdG9zIHN5bmNlZA")
                == .set(id: nil, ProgramStatusRecord(state: .done, msg: "Photos synced")))
    }

    @Test func base64ThatDoesNotDecodeDiscardsTheReport() {
        // Inside the pair grammar but not base64: `.` and `,` are not in the
        // alphabet, and five characters cannot be a whole number of bytes.
        #expect(ProgramStatusReport.parse("state=done:msg=a.b,c") == nil)
        #expect(ProgramStatusReport.parse("state=done:msg=aGkhh") == nil)
    }

    @Test func textThatIsNotUTF8DiscardsTheReport() {
        #expect(ProgramStatusReport.parse("state=done:msg=/w==") == nil)
    }

    @Test func aControlCharacterInTheTextDiscardsTheReport() {
        // "a\nb", and a C1 control (U+0085, NEL) followed by "x".
        #expect(ProgramStatusReport.parse("state=done:msg=YQpi") == nil)
        #expect(ProgramStatusReport.parse("state=done:title=woV4") == nil)
    }

    @Test func invisibleFormattingIsDisarmed() {
        // U+202E RIGHT-TO-LEFT OVERRIDE before "evil", and U+200B ZERO WIDTH SPACE
        // between "a" and "b": shown outside the grid, either can make a message read
        // as something it is not.
        #expect(ProgramStatusReport.parse("state=done:msg=4oCuZXZpbA==:title=YeKAi2I=")
                == .set(id: nil, ProgramStatusRecord(state: .done, title: "ab", msg: "evil")))
    }

    @Test func aTitlePastItsEncodedLimitDiscardsTheReport() {
        // 192 bytes encode to 256 characters, the limit; 193 encode to 260.
        let fits = Data(repeating: UInt8(ascii: "x"), count: 192).base64EncodedString()
        let over = Data(repeating: UInt8(ascii: "x"), count: 193).base64EncodedString()
        #expect(ProgramStatusReport.parse("state=done:title=\(fits)") != nil)
        #expect(ProgramStatusReport.parse("state=done:title=\(over)") == nil)
    }

    @Test func aMessagePastItsDecodedLimitDiscardsTheReport() {
        // 2048 and 2049 bytes both encode to exactly 2732 characters, so only the
        // decoded size tells them apart.
        let fits = Data(repeating: UInt8(ascii: "x"), count: 2048).base64EncodedString()
        let over = Data(repeating: UInt8(ascii: "x"), count: 2049).base64EncodedString()
        #expect(fits.count == 2732 && over.count == 2732)
        #expect(ProgramStatusReport.parse("state=done:msg=\(fits)") != nil)
        #expect(ProgramStatusReport.parse("state=done:msg=\(over)") == nil)
    }

    @Test func aMessagePastItsEncodedLimitDiscardsTheReport() {
        #expect(ProgramStatusReport.parse("state=done:msg=\(String(repeating: "A", count: 2736))") == nil)
    }

    @Test func aDiscardedTextValueTakesTheWholeReportWithIt() {
        // A valid state and app do not survive a bad message beside them.
        #expect(ProgramStatusReport.parse("state=error:app=brew:msg=YQpi") == nil)
    }
}
