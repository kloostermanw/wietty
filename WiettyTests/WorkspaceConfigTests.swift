import Testing
import Foundation
@testable import Wietty

@Suite struct WorkspaceConfigTests {
    /// The user facing wording for a file that fails to parse.
    private func failureMessage(for json: Data) throws -> String {
        let error = try #require(#expect(throws: WorkspaceConfigError.self) {
            try WorkspaceConfig.parse(json)
        })
        return try #require(error.errorDescription)
    }

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
        #expect(throws: WorkspaceConfigError.missingKey("terminals")) {
            try WorkspaceConfig.parse(json)
        }
    }

    /// The clean break guarantees every workspace written before the rename fails
    /// this way, so the message has to name the key and say what to do about it.
    /// Foundation's own wording for a missing key is "The data couldn't be read
    /// because it is missing", which names neither the file nor the key.
    @Test func aMissingKeySaysWhichKeyAndHowToFixIt() throws {
        let json = Data("""
        { "name": "laravel-test", "agents": [], "iterm": ["Terminal 1"] }
        """.utf8)
        let message = try failureMessage(for: json)
        #expect(message.contains(ConfigFile.fileName))
        #expect(message.contains("terminals"))
        #expect(message.contains("iterm"))
        #expect(!message.contains("The data couldn't be read"))
    }

    /// A key other than `terminals` gets the same treatment minus the rename hint,
    /// which only makes sense for the one key the rename moved.
    @Test func anotherMissingKeyIsNamedWithoutTheRenameHint() throws {
        let json = Data("""
        { "name": "laravel-test", "terminals": ["Terminal 1"] }
        """.utf8)
        let message = try failureMessage(for: json)
        #expect(message.contains("agents"))
        #expect(!message.contains("iterm"))
    }

    /// A file that is not JSON at all is a different failure from a missing key and
    /// must not claim a key is missing.
    @Test func malformedJsonIsReportedAsMalformed() throws {
        let message = try failureMessage(for: Data("{ not json".utf8))
        #expect(message.contains(ConfigFile.fileName))
        #expect(!message.contains("missing the required"))
    }

    /// A key that is present but holds the wrong type is neither missing nor
    /// malformed JSON, and saying "missing" would send the reader looking for a key
    /// that is right there.
    @Test func aWrongTypeNamesTheKeyWithoutCallingItMissing() throws {
        let json = Data("""
        { "agents": [], "terminals": "Terminal 1" }
        """.utf8)
        let message = try failureMessage(for: json)
        #expect(message.contains("terminals"))
        #expect(!message.contains("missing the required"))
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

    /// The two naming fields are read from an agent entry when present. See issue #37.
    @Test func parsesAgentNamingFields() throws {
        let json = Data("""
        {
          "agents": [
            { "slot": "Claude 5", "type": "claude", "fixed_naming": true, "prefix": "[default]" }
          ],
          "terminals": []
        }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.agents.first?.fixedNaming == true)
        #expect(config.agents.first?.prefix == "[default]")
    }

    /// A file written before the fields, or one that just leaves them out, reads with
    /// the documented defaults: dynamic naming, no prefix.
    @Test func agentNamingFieldsDefaultWhenOmitted() throws {
        let json = Data("""
        { "agents": [ { "slot": "Claude 1", "type": "claude" } ], "terminals": [] }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.agents.first?.fixedNaming == false)
        #expect(config.agents.first?.prefix == "")
    }

    /// Defaults are not written back, so an existing file does not gain
    /// `fixed_naming`/`prefix` noise the first time the app rewrites it.
    @Test func encodingOmitsDefaultNamingFields() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [.init(slot: "Claude 1", type: "claude")], terminals: [])
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!text.contains("fixed_naming"))
        #expect(!text.contains("prefix"))
    }

    /// A set field is written and survives a round trip, so a hand written or
    /// app-set value is preserved when the file is rewritten.
    @Test func encodesAndRoundTripsSetNamingFields() throws {
        let config = WorkspaceConfig(
            name: nil,
            agents: [.init(slot: "Claude 5", type: "claude", fixedNaming: true, prefix: "[default]")],
            terminals: [])
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("fixed_naming"))
        #expect(text.contains("[default]"))
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored == config)
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

    @Test func parsesChecksSection() throws {
        let json = Data("""
        {
          "agents": [], "terminals": [],
          "checks": {
            "composer": { "command": "check-composer", "message": "run composer install" },
            "npm": { "command": "check-npm" }
          }
        }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.checks?["composer"]?.command == "check-composer")
        #expect(config.checks?["composer"]?.message == "run composer install")
        #expect(config.checks?["npm"]?.command == "check-npm")
    }

    /// A check with only a `command` reads, its `message` defaulting to empty, the
    /// same way a test written with only a command does.
    @Test func checkMessageDefaultsToEmptyWhenOmitted() throws {
        let json = Data("""
        { "agents": [], "terminals": [], "checks": { "npm": { "command": "check-npm" } } }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.checks?["npm"]?.message == "")
    }

    @Test func absentChecksSectionIsNil() throws {
        let json = Data("""
        { "name": "x", "agents": [], "terminals": [] }
        """.utf8)
        #expect(try WorkspaceConfig.parse(json).checks == nil)
    }

    /// An empty `message` is not written back, so a check defined with only a
    /// command does not gain `"message": ""` noise the first time the file is
    /// rewritten.
    @Test func encodingOmitsEmptyCheckMessage() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            checks: ["npm": CheckConfig(command: "check-npm")]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!text.contains("message"))
    }

    @Test func roundTripsChecksSection() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            checks: ["composer": CheckConfig(command: "check-composer", message: "run composer install")]
        )
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored == config)
    }

    /// A check's `watch` file is parsed, so a passing run can be remembered against
    /// it and the command skipped until the file changes.
    @Test func parsesCheckWatch() throws {
        let json = Data("""
        { "agents": [], "terminals": [],
          "checks": { "vendor": { "command": "check", "watch": "composer.lock" } } }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.checks?["vendor"]?.watch == "composer.lock")
    }

    /// An empty `watch` reads as none, so a blank field does not turn caching half on.
    @Test func blankCheckWatchDecodesAsNil() throws {
        let json = Data("""
        { "agents": [], "terminals": [], "checks": { "x": { "command": "check", "watch": "" } } }
        """.utf8)
        #expect(try WorkspaceConfig.parse(json).checks?["x"]?.watch == nil)
    }

    /// A check with no `watch` is not written with a null one, so an ordinary check
    /// does not gain `"watch"` noise the first time the file is rewritten.
    @Test func encodingOmitsAbsentCheckWatch() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            checks: ["npm": CheckConfig(command: "check-npm")]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(!text.contains("watch"))
    }
}
