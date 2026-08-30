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
        #expect(text.contains("\"command\""))
        #expect(!text.contains("\"allow_empty_vars\""))
        #expect(!text.contains("\"shell_init\""))
        #expect(!text.contains("\"env\""))
    }

    /// The non-default branches, exercised through the real write path
    /// (`WorkspaceConfig.encoded()`): a set `env`/`allow_empty_vars`/`shell_init`
    /// is written, a slash in a command or shell line is not escaped, and the
    /// whole thing round trips. Guards against dropping a set field or escaping
    /// slashes in the `tests` section.
    @Test func encodingKeepsSetFieldsAndDoesNotEscapeSlashes() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            tests: ["fixer": TestConfig(
                command: "/usr/local/bin/php-cs-fixer fix",
                env: ["APP_ENV": "testing"], allowEmptyVars: true,
                shellInit: ["source /opt/venv/bin/activate"])]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("\"env\""))
        #expect(text.contains("\"allow_empty_vars\""))
        #expect(text.contains("\"shell_init\""))
        #expect(text.contains("/usr/local/bin/php-cs-fixer fix"))
        #expect(text.contains("source /opt/venv/bin/activate"))
        #expect(!text.contains("\\/"))
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored == config)
    }
}
