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
}
