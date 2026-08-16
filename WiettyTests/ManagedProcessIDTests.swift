import Testing
import Foundation
@testable import Wietty

/// The copy-and-paste handle for a managed process or test. It is what the "Copy ID
/// for agent" row action puts on the pasteboard and what the MCP tools resolve back to
/// a live `ManagedProcess`, so its encoding is a fact about the tool contract and
/// belongs in CI rather than only being checkable by pasting one into an agent.
///
/// Unlike a terminal's `sessionId`, a `ManagedProcess` has no persisted identifier: its
/// runtime `id` is a fresh `UUID` regenerated on every config reload. The stable
/// identity is `(projectId, kind, name)`, and a process and a test may share a name, so
/// the kind has to be part of the handle.
@Suite struct ManagedProcessIDTests {
    private let project = UUID()

    @Test func aProcessHandleRoundTrips() {
        let raw = ManagedProcessID.string(projectId: project, name: "queue", isTest: false)
        let parsed = ManagedProcessID.parse(raw)
        #expect(parsed == ManagedProcessID.Parsed(projectId: project, name: "queue", isTest: false))
    }

    @Test func aTestHandleRoundTripsAndIsDistinctFromAProcessOfTheSameName() {
        let processRaw = ManagedProcessID.string(projectId: project, name: "phpunit", isTest: false)
        let testRaw = ManagedProcessID.string(projectId: project, name: "phpunit", isTest: true)
        #expect(processRaw != testRaw)
        #expect(ManagedProcessID.parse(testRaw)
            == ManagedProcessID.Parsed(projectId: project, name: "phpunit", isTest: true))
    }

    /// A process name is a `wietty.json` key and can contain a colon, so the encoding
    /// must survive one rather than truncating the name at the first `:`.
    @Test func aNameContainingAColonRoundTrips() {
        let raw = ManagedProcessID.string(projectId: project, name: "build:web", isTest: false)
        #expect(ManagedProcessID.parse(raw)?.name == "build:web")
    }

    @Test func gibberishParsesToNil() {
        #expect(ManagedProcessID.parse("not-an-id") == nil)
        #expect(ManagedProcessID.parse("") == nil)
    }

    @Test func aBadProjectUUIDParsesToNil() {
        #expect(ManagedProcessID.parse("not-a-uuid:process:queue") == nil)
    }

    @Test func anUnknownKindParsesToNil() {
        #expect(ManagedProcessID.parse("\(project.uuidString):daemon:queue") == nil)
    }

    @Test func anEmptyNameParsesToNil() {
        #expect(ManagedProcessID.parse("\(project.uuidString):process:") == nil)
    }
}
