import Testing
import Foundation
@testable import Wietty

@Suite struct TestConfigTests {
    @Test func decodesAllFields() throws {
        let json = Data("""
        {
          "command": "php-cs-fixer fix -v --dry-run",
          "env": { "APP_ENV": "testing" },
          "allow_empty_vars": true
        }
        """.utf8)
        let cfg = try JSONDecoder().decode(TestConfig.self, from: json)
        #expect(cfg.command == "php-cs-fixer fix -v --dry-run")
        #expect(cfg.env == ["APP_ENV": "testing"])
        #expect(cfg.allowEmptyVars == true)
    }

    @Test func appliesDefaults() throws {
        let json = Data("""
        { "command": "vendor/bin/phpstan analyse" }
        """.utf8)
        let cfg = try JSONDecoder().decode(TestConfig.self, from: json)
        #expect(cfg.command == "vendor/bin/phpstan analyse")
        #expect(cfg.env == [:])
        #expect(cfg.allowEmptyVars == false)
        #expect(cfg.shellInit == [])
    }

    /// The app re-encodes the test definitions it decoded whenever it rewrites
    /// `wietty.json` for a row change, so a field missing from the encoding is
    /// silently deleted from the user's file.
    @Test func encodesShellInit() throws {
        let cfg = TestConfig(
            command: "vendor/bin/phpstan analyse", shellInit: ["source ./.venv/bin/activate"]
        )
        let data = try JSONEncoder().encode(cfg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("shell_init")) // the wire name, not the Swift one
        let reread = try JSONDecoder().decode(TestConfig.self, from: data)
        #expect(reread.shellInit == ["source ./.venv/bin/activate"])
    }

    @Test func decodesShellInit() throws {
        let json = Data("""
        {
          "command": "vendor/bin/phpstan analyse",
          "shell_init": ["source ./.venv/bin/activate"]
        }
        """.utf8)
        let cfg = try JSONDecoder().decode(TestConfig.self, from: json)
        #expect(cfg.shellInit == ["source ./.venv/bin/activate"])
    }

    /// Like a process definition, a re-encoded test definition must not gain
    /// `env: {}`, `allow_empty_vars: false` and `shell_init: []` the first time
    /// the app rewrites the file. Only `command` is always written.
    @Test func encodingOmitsDefaultAndEmptyFields() throws {
        let data = try JSONEncoder().encode(TestConfig(command: "vendor/bin/phpstan analyse"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("command"))
        #expect(!text.contains("allow_empty_vars"))
        #expect(!text.contains("shell_init"))
        #expect(!text.contains("env"))
    }
}
