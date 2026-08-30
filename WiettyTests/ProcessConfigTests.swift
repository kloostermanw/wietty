import Testing
import Foundation
@testable import Wietty

@Suite struct ProcessConfigTests {
    @Test func decodesAllFields() throws {
        let json = Data("""
        {
          "agents": [],
          "terminals": [],
          "processes": {
            "sail": {
              "command": "cd src && sail up -d",
              "kind": "daemon",
              "stop": "cd src && sail down",
              "status": "cd src && sail ps | grep -q Up",
              "auto_start": true,
              "auto_restart": false,
              "restart_when_changed": ["a", "b"],
              "env": { "APP_ENV": "local" },
              "allow_empty_vars": true
            }
          }
        }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        let sail = try #require(config.processes?["sail"])
        #expect(sail.command == "cd src && sail up -d")
        #expect(sail.kind == .daemon)
        #expect(sail.stop == "cd src && sail down")
        #expect(sail.status == "cd src && sail ps | grep -q Up")
        #expect(sail.autoStart == true)
        #expect(sail.autoRestart == false)
        #expect(sail.restartWhenChanged == ["a", "b"])
        #expect(sail.env == ["APP_ENV": "local"])
        #expect(sail.allowEmptyVars == true)
    }

    @Test func appliesDefaults() throws {
        let json = Data("""
        { "agents": [], "terminals": [], "processes": { "npm": { "command": "npm run dev" } } }
        """.utf8)
        let npm = try #require(try WorkspaceConfig.parse(json).processes?["npm"])
        #expect(npm.kind == .longRunning)
        #expect(npm.stop == nil)
        #expect(npm.status == nil)
        #expect(npm.autoStart == false)
        #expect(npm.autoRestart == false)
        #expect(npm.restartWhenChanged == [])
        #expect(npm.env == [:])
        #expect(npm.allowEmptyVars == false)
        #expect(npm.shellInit == [])
    }

    @Test func decodesShellInit() throws {
        let json = Data("""
        {
          "agents": [], "terminals": [],
          "processes": {
            "npm": {
              "command": "npm run dev",
              "shell_init": ["export PATH=$HOME/bin:$PATH", "source ~/bin/env.sh"]
            }
          }
        }
        """.utf8)
        let npm = try #require(try WorkspaceConfig.parse(json).processes?["npm"])
        #expect(npm.shellInit == ["export PATH=$HOME/bin:$PATH", "source ~/bin/env.sh"])
    }

    @Test func legacyConfigWithoutProcessesStillParses() throws {
        let json = Data("""
        { "name": "x", "agents": [], "terminals": [] }
        """.utf8)
        let config = try WorkspaceConfig.parse(json)
        #expect(config.processes == nil)
    }

    /// The app re-encodes the process definitions it decoded whenever it rewrites
    /// `wietty.json` for a row change. A minimal definition must come back minimal,
    /// not sprout `auto_start: false`, `env: {}` and the rest of the defaults.
    /// `command` and `kind` are always written; everything else only when set.
    @Test func encodingOmitsDefaultAndEmptyFields() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            processes: ["npm": ProcessConfig(command: "npm run dev")]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("\"command\""))
        #expect(text.contains("\"kind\""))
        #expect(!text.contains("auto_start"))
        #expect(!text.contains("auto_restart"))
        #expect(!text.contains("allow_empty_vars"))
        #expect(!text.contains("restart_when_changed"))
        #expect(!text.contains("shell_init"))
        #expect(!text.contains("\"env\""))
        #expect(!text.contains("\"stop\""))
        #expect(!text.contains("\"status\""))
    }

    /// A set field is written and survives a round trip, so a hand written or
    /// decoded value is preserved when the file is rewritten.
    @Test func encodingKeepsSetFieldsAndRoundTrips() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            processes: ["sail": ProcessConfig(
                command: "sail up -d", kind: .daemon, stop: "sail down", status: "sail ps",
                autoStart: true, autoRestart: true, restartWhenChanged: [".env"],
                env: ["APP_ENV": "local"], allowEmptyVars: true, shellInit: ["source .env"])]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("auto_start"))
        #expect(text.contains("auto_restart"))
        #expect(text.contains("allow_empty_vars"))
        #expect(text.contains("restart_when_changed"))
        #expect(text.contains("shell_init"))
        let restored = try WorkspaceConfig.parse(config.encoded())
        #expect(restored == config)
    }

    /// The whole point of the issue: a command path is written with real slashes,
    /// not the `\/` Foundation escapes by default.
    @Test func encodingDoesNotEscapeSlashesInCommand() throws {
        let config = WorkspaceConfig(
            name: nil, agents: [], terminals: [],
            processes: ["fork": ProcessConfig(
                command: "/usr/local/bin/fork $WIETTY_WORKSPACE_PATH", kind: .shortRunning)]
        )
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(text.contains("/usr/local/bin/fork $WIETTY_WORKSPACE_PATH"))
        #expect(!text.contains("\\/"))
    }
}
