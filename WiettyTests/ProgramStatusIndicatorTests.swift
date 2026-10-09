import Testing
import Foundation
@testable import Wietty

/// What a row draws for the program status its terminal reported.
@Suite struct ProgramStatusIndicatorTests {
    private func indicator(_ record: ProgramStatusRecord) -> ProgramStatusIndicator? {
        ProgramStatusIndicator(record)
    }

    @Test func anIdleProgramDrawsNothing() {
        // At rest is what a terminal is when nothing is said at all.
        #expect(indicator(ProgramStatusRecord(state: .idle, msg: "Ready")) == nil)
    }

    @Test func aWorkingProgramSpins() {
        let working = indicator(ProgramStatusRecord(state: .working))
        #expect(working?.glyph == .spinner)
        #expect(working?.text == nil)
        #expect(working?.tint == .neutral)
    }

    @Test func aWorkingProgramWithProgressShowsThePercentage() {
        #expect(indicator(ProgramStatusRecord(state: .working, progress: 40))?.text == "40%")
    }

    @Test func aBlockedProgramSaysItNeedsYou() {
        let blocked = indicator(ProgramStatusRecord(state: .blocked, progress: 40))
        #expect(blocked?.text == "needs you")
        #expect(blocked?.tint == .attention)
    }

    @Test func whatABlockedProgramWaitsForChangesTheGlyph() {
        let kinds: [ProgramStatusKind?] = [nil, .permission, .question, .auth]
        let glyphs = kinds.map {
            indicator(ProgramStatusRecord(state: .blocked, kind: $0))?.glyph
        }
        #expect(Set(glyphs.compactMap { $0 }).count == 4)
        #expect(!glyphs.contains(.spinner))
    }

    @Test func doneAndErrorAreTintedApart() {
        let done = indicator(ProgramStatusRecord(state: .done))
        let error = indicator(ProgramStatusRecord(state: .error))
        #expect(done?.tint == .success)
        #expect(error?.tint == .failure)
        #expect(done?.glyph != error?.glyph)
        #expect(done?.text == nil && error?.text == nil)
    }

    @Test func theTooltipIsTheProgramsMessage() {
        #expect(indicator(ProgramStatusRecord(state: .done, msg: "Upgraded 12 packages"))?.tooltip
                == "Upgraded 12 packages")
    }

    @Test func theTooltipNamesTheRecordWhenItHasATitle() {
        #expect(indicator(ProgramStatusRecord(state: .blocked, title: "EU West", msg: "Approve deploy?"))?.tooltip
                == "EU West: Approve deploy?")
    }

    @Test func withoutAMessageTheTooltipSaysWhatTheStateMeans() {
        #expect(indicator(ProgramStatusRecord(state: .working))?.tooltip == "Working")
        #expect(indicator(ProgramStatusRecord(state: .blocked, kind: .question))?.tooltip == "Waiting for your answer")
        #expect(indicator(ProgramStatusRecord(state: .error, title: "Lint"))?.tooltip == "Lint: Failed")
    }
}
