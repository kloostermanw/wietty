import Testing
import Foundation
@testable import Wietty

/// One terminal's set of program status records (sections 4 and 5).
@Suite struct ProgramStatusRecordsTests {
    private func records(_ reports: [ProgramStatusReport]) -> ProgramStatusRecords {
        var records = ProgramStatusRecords()
        for report in reports { records.apply(report) }
        return records
    }

    @Test func anEmptySetHasNoSummary() {
        #expect(ProgramStatusRecords().summary == nil)
        #expect(ProgramStatusRecords().isEmpty)
    }

    @Test func aReportSetsTheRootRecord() {
        let set = records([.set(id: nil, ProgramStatusRecord(state: .working, app: "brew", msg: "Installing"))])
        #expect(set.summary == ProgramStatusRecord(state: .working, app: "brew", msg: "Installing"))
    }

    @Test func aReportReplacesItsRecordCompletely() {
        // Keys left out of the second report are gone, not carried over.
        let set = records([
            .set(id: nil, ProgramStatusRecord(state: .working, app: "brew", msg: "Installing")),
            .set(id: nil, ProgramStatusRecord(state: .done)),
        ])
        #expect(set.summary == ProgramStatusRecord(state: .done))
    }

    @Test func clearingAnIdRemovesItAndEverythingBeneathIt() {
        var set = records([
            .set(id: nil, ProgramStatusRecord(state: .idle)),
            .set(id: "a", ProgramStatusRecord(state: .blocked)),
            .set(id: "a/b", ProgramStatusRecord(state: .error)),
            // Starts with "a" but is a sibling, not a child.
            .set(id: "ab", ProgramStatusRecord(state: .working)),
        ])
        set.apply(.clear(id: "a"))
        #expect(set.summary == ProgramStatusRecord(state: .working))
    }

    @Test func clearingWithoutAnIdRemovesEverything() {
        var set = records([
            .set(id: nil, ProgramStatusRecord(state: .idle)),
            .set(id: "a/b", ProgramStatusRecord(state: .error)),
        ])
        set.apply(.clear(id: nil))
        #expect(set.isEmpty)
        #expect(set.summary == nil)
    }

    @Test func aRecordWithoutAnAppTakesTheNearestAncestorsApp() {
        let set = records([
            .set(id: nil, ProgramStatusRecord(state: .working, app: "deploy")),
            .set(id: "us", ProgramStatusRecord(state: .working, app: "region")),
            .set(id: "us/east", ProgramStatusRecord(state: .blocked, msg: "Approve?")),
        ])
        #expect(set.summary == ProgramStatusRecord(state: .blocked, app: "region", msg: "Approve?"))
    }

    @Test func anAncestorNeedNotExistForInheritanceToSkipIt() {
        let set = records([
            .set(id: nil, ProgramStatusRecord(state: .working, app: "deploy")),
            .set(id: "eu/west", ProgramStatusRecord(state: .error)),
        ])
        #expect(set.summary == ProgramStatusRecord(state: .error, app: "deploy"))
    }

    @Test func theMostUrgentRecordIsTheSummary() {
        var set = records([
            .set(id: nil, ProgramStatusRecord(state: .idle)),
            .set(id: "d", ProgramStatusRecord(state: .done)),
        ])
        #expect(set.summary?.state == .done)
        set.apply(.set(id: "w", ProgramStatusRecord(state: .working)))
        #expect(set.summary?.state == .working)
        set.apply(.set(id: "e", ProgramStatusRecord(state: .error)))
        #expect(set.summary?.state == .error)
        set.apply(.set(id: "b", ProgramStatusRecord(state: .blocked)))
        #expect(set.summary?.state == .blocked)
    }

    @Test func theRootRecordWinsATie() {
        let set = records([
            .set(id: nil, ProgramStatusRecord(state: .working, msg: "root")),
            .set(id: "child", ProgramStatusRecord(state: .working, msg: "child")),
        ])
        #expect(set.summary?.msg == "root")
    }

    @Test func theMostRecentlyUpdatedChildWinsATie() {
        var set = records([
            .set(id: "a", ProgramStatusRecord(state: .working, msg: "a")),
            .set(id: "b", ProgramStatusRecord(state: .working, msg: "b")),
        ])
        #expect(set.summary?.msg == "b")
        set.apply(.set(id: "a", ProgramStatusRecord(state: .working, msg: "a again")))
        #expect(set.summary?.msg == "a again")
    }

    @Test func removingStatesKeepsTheOthers() {
        var set = records([
            .set(id: nil, ProgramStatusRecord(state: .blocked)),
            .set(id: "w", ProgramStatusRecord(state: .working)),
            .set(id: "i", ProgramStatusRecord(state: .idle)),
            .set(id: "d", ProgramStatusRecord(state: .done, msg: "kept")),
        ])
        set.remove([.working, .blocked, .idle])
        #expect(set.summary == ProgramStatusRecord(state: .done, msg: "kept"))
        set.remove([.done, .error])
        #expect(set.isEmpty)
    }

    @Test func removeAllEmptiesTheSet() {
        var set = records([.set(id: "x", ProgramStatusRecord(state: .done))])
        set.removeAll()
        #expect(set.isEmpty)
    }

    /// Fills the set to its 256 record cap: `first` at `r0`, `second` at `r1`, and
    /// idle records after them, in that order of update.
    private func full(first: ProgramStatusState, second: ProgramStatusState) -> ProgramStatusRecords {
        var set = records([
            .set(id: "r0", ProgramStatusRecord(state: first)),
            .set(id: "r1", ProgramStatusRecord(state: second)),
        ])
        for index in 2..<256 { set.apply(.set(id: "r\(index)", ProgramStatusRecord(state: .idle))) }
        return set
    }

    @Test func aNewRecordPastTheCapEvictsTheLeastRecentlyUpdated() {
        var set = full(first: .blocked, second: .error)
        // Touching r0 makes r1 the least recently updated, though r0 is older.
        set.apply(.set(id: "r0", ProgramStatusRecord(state: .blocked)))
        set.apply(.set(id: "new", ProgramStatusRecord(state: .idle)))
        set.apply(.clear(id: "r0"))
        #expect(set.summary?.state == .idle)
    }

    @Test func replacingARecordAtTheCapEvictsNothing() {
        var set = full(first: .error, second: .idle)
        set.apply(.set(id: "r1", ProgramStatusRecord(state: .idle)))
        #expect(set.summary?.state == .error)
    }
}
