import Testing
import Foundation
@testable import Wietty

@Suite struct TerminalRefTests {
    @Test func slotDefaultsToLabelWhenUnspecified() {
        let ref = TerminalRef(label: "Terminal 1", sessionId: "s")
        #expect(ref.slot == "Terminal 1")
    }

    @Test func slotCanBeSetExplicitly() {
        let ref = TerminalRef(label: "fix auth", sessionId: "s", kind: .claude, slot: "claude1")
        #expect(ref.slot == "claude1")
        #expect(ref.label == "fix auth")
    }

    @Test func decodesLegacyRefWithoutSlotUsingLabel() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","label":"Terminal 1","sessionId":"sess-A","kind":"terminal"}
        """.utf8)
        let ref = try JSONDecoder().decode(TerminalRef.self, from: json)
        #expect(ref.slot == "Terminal 1")
    }

    /// Every row stored before agents were configurable carries no command, which
    /// is how a row says "whatever my kind runs": `claude` for an agent row, a bare
    /// shell for a terminal.
    @Test func decodesLegacyRefWithoutCommandAsNil() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","label":"Claude 1","sessionId":"sess-A","kind":"claude"}
        """.utf8)
        let ref = try JSONDecoder().decode(TerminalRef.self, from: json)
        #expect(ref.command == nil)
    }

    @Test func roundTripsTheCommandARowWasOpenedWith() throws {
        let ref = TerminalRef(label: "Codex 1", sessionId: "s", kind: .claude,
                              command: "codex --model o3")
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(TerminalRef.self, from: data).command == "codex --model o3")
    }

    @Test func roundTripsSlot() throws {
        let ref = TerminalRef(label: "fix auth", sessionId: "s", kind: .claude, slot: "claude1")
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(TerminalRef.self, from: data)
        #expect(decoded.slot == "claude1")
    }

    // MARK: Naming (issue #37)

    /// A prefix sits in front of the label with one space; the label already holds
    /// whichever name won (slot, reported title, or manual rename).
    @Test func displayNamePrependsPrefix() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s", kind: .claude, slot: "Claude 5",
                              prefix: "[default]")
        #expect(ref.displayName == "[default] Claude 5")
    }

    /// An empty prefix means no prefix and, with it, no stray leading space.
    @Test func displayNameWithEmptyPrefixIsJustTheLabel() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s", kind: .claude, slot: "Claude 5",
                              prefix: "")
        #expect(ref.displayName == "Claude 5")
    }

    /// A whitespace only prefix reads as none, and a trailing space in the prefix
    /// does not double the separator.
    @Test func displayNameTrimsThePrefix() {
        #expect(TerminalRef(label: "Claude 5", sessionId: "s", prefix: "   ").displayName == "Claude 5")
        #expect(TerminalRef(label: "Claude 5", sessionId: "s", prefix: "[default] ").displayName
                == "[default] Claude 5")
    }

    /// The prefix follows the label, so a reported title (which lands in `label`)
    /// still shows the prefix in front of it.
    @Test func displayNamePrefixesAReportedTitle() {
        let ref = TerminalRef(label: "running tests", sessionId: "s", kind: .claude,
                              slot: "Claude 5", prefix: "[default]")
        #expect(ref.displayName == "[default] running tests")
    }

    /// Under `fixedNaming` the shown name is the slot, not a `label` that a reported
    /// title already moved. This is what makes turning the flag on take effect at once
    /// rather than only when the row is reopened. See issue #37.
    @Test func displayNameUsesSlotWhenFixedEvenIfLabelDiverged() {
        let ref = TerminalRef(label: "running tests", sessionId: "s", kind: .claude,
                              slot: "Claude 5", fixedNaming: true, prefix: "[default]")
        #expect(ref.displayName == "[default] Claude 5")
    }

    // MARK: Live title override (issue #60)

    /// A live agent-reported title overrides the stored `label` for display without
    /// changing the row's persisted name. The prefix still sits in front of it, the
    /// same as it does for the stored label.
    @Test func displayNameWithLiveLabelShowsTheReportedTitle() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s", kind: .claude,
                              slot: "Claude 5", prefix: "[default]")
        #expect(ref.displayName(liveLabel: "running tests") == "[default] running tests")
    }

    /// No override is the stored name: `displayName(liveLabel: nil)` is exactly the
    /// `displayName` property.
    @Test func displayNameWithNilLiveLabelIsTheStoredName() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s", kind: .claude, prefix: "[default]")
        #expect(ref.displayName(liveLabel: nil) == ref.displayName)
    }

    /// A `fixed_naming` row ignores the live title the same way it ignores a reported
    /// title that reached `label`: the slot wins. The live override never applies.
    @Test func displayNameWithLiveLabelIsIgnoredWhenFixed() {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s", kind: .claude,
                              slot: "Claude 5", fixedNaming: true, prefix: "[default]")
        #expect(ref.displayName(liveLabel: "running tests") == "[default] Claude 5")
    }

    /// A row stored before the naming fields decodes with the defaults: dynamic
    /// naming, no prefix.
    @Test func decodesLegacyRefWithoutNamingFields() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","label":"Claude 1","sessionId":"sess-A","kind":"claude"}
        """.utf8)
        let ref = try JSONDecoder().decode(TerminalRef.self, from: json)
        #expect(ref.fixedNaming == false)
        #expect(ref.prefix == "")
    }

    @Test func roundTripsNamingFields() throws {
        let ref = TerminalRef(label: "Claude 5", sessionId: "s", kind: .claude, slot: "Claude 5",
                              fixedNaming: true, prefix: "[default]")
        let decoded = try JSONDecoder().decode(TerminalRef.self, from: JSONEncoder().encode(ref))
        #expect(decoded.fixedNaming == true)
        #expect(decoded.prefix == "[default]")
    }
}
