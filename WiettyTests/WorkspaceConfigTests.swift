import Testing
import Foundation
@testable import Wietty

@Suite struct WorkspaceConfigTests {
    @Test func parsesSampleFile() throws {
        let json = Data("""
        {
          "name": "laravel-test",
          "agents": [
            { "slot": "claude1", "type": "claude" },
            { "slot": "claude2", "type": "claude" }
          ],
          "terminals": ["Terminal 1", "Terminal 2"]
        }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.name == "laravel-test")
        #expect(config.agents.map(\.slot) == ["claude1", "claude2"])
        #expect(config.agents.allSatisfy { $0.type == "claude" })
        #expect(config.terminals == ["Terminal 1", "Terminal 2"])
    }

    /// `terminals` replaces `iterm` outright. The old key is not a synonym, so a
    /// file that still uses it is missing a required key and fails to parse, which
    /// is the loud failure the rename is meant to produce.
    @Test func theOldItermKeyIsNotAccepted() throws {
        let json = Data("""
        { "name": "laravel-test", "agents": [], "iterm": ["Terminal 1"] }
        """.utf8)
        #expect(throws: DecodingError.self) { try WorkspaceConfig.parse(json) }
    }

    @Test func encodesTerminalsUnderItsOwnKey() throws {
        let config = WorkspaceConfig(name: nil, agents: [], terminals: ["Terminal 1"])
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("\"terminals\""))
        #expect(!text.contains("\"iterm\""))
    }

    @Test func roundTripsThroughEncodeAndParse() throws {
        let config = WorkspaceConfig(
            name: "acme",
            agents: [.init(slot: "claude1", type: "claude")],
            terminals: ["Terminal 1", "Terminal 2"]
        )
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored == config)
    }

    @Test func omitsNilNameWhenEncoding() throws {
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [])
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!text.contains("name"))
    }

    @Test func encodesArrayOrderStably() throws {
        let config = WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "b", type: "claude"), .init(slot: "a", type: "claude")],
            terminals: []
        )
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored.agents.map(\.slot) == ["b", "a"])
    }

    @Test func parsesTestsSection() throws {
        let json = Data("""
        {
          "agents": [], "terminals": [],
          "tests": {
            "phpstan": { "command": "vendor/bin/phpstan analyse" },
            "php-cs-fixer": { "command": "php-cs-fixer fix --dry-run", "allow_empty_vars": true }
          }
        }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.tests?["phpstan"]?.command == "vendor/bin/phpstan analyse")
        #expect(config.tests?["php-cs-fixer"]?.allowEmptyVars == true)
    }

    @Test func absentTestsSectionIsNil() throws {
        let json = Data("""
        { "name": "x", "agents": [], "terminals": [] }
        """.utf8)
        #expect(try WorkspaceConfig.parse(json).tests == nil)
    }

    @Test func parsesTopLevelShellInit() throws {
        let json = Data("""
        {
          "agents": [], "terminals": [],
          "shell_init": [
            "export EDITOR='vim'",
            "export PATH=$HOME/bin:$PATH",
            "source ~/bin/env.sh"
          ]
        }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.shellInit == [
            "export EDITOR='vim'",
            "export PATH=$HOME/bin:$PATH",
            "source ~/bin/env.sh",
        ])
    }

    @Test func absentShellInitIsNil() throws {
        let json = Data("""
        { "name": "x", "agents": [], "terminals": [] }
        """.utf8)
        #expect(try WorkspaceConfig.parse(json).shellInit == nil)
    }

    @Test func encodesShellInitUnderItsSnakeCaseKey() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [], shellInit: ["export PATH=$HOME/bin:$PATH"]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("\"shell_init\""))
        #expect(try WorkspaceConfig.parse(config.encoded()) == config)
    }

    @Test func omitsNilShellInitWhenEncoding() throws {
        let config = WorkspaceConfig(name: nil, agents: [], terminals: [])
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!text.contains("shell_init"))
    }

    @Test func roundTripsTestsSection() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            tests: ["phpunit": TestConfig(command: "php artisan test")]
        )
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored == config)
    }
}
