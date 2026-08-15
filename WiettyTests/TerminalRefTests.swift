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
}
