import Foundation

struct CommandResult: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var status: Int32
}

protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?,
             environment: [String: String]) -> CommandResult
}

extension CommandRunning {
    /// Runs with no injected variables, inheriting the app's environment. The common
    /// case for callers (like `GitInfoService`) that do not need `WIETTY_*` values.
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) -> CommandResult {
        run(executable, arguments, workingDirectory: workingDirectory, environment: [:])
    }
}

struct ProcessCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?,
             environment: [String: String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        // Layer the injected variables over the inherited environment (injected values
        // win), so the login shell still sees PATH/HOME while gaining the `WIETTY_*`
        // values. Left untouched when nothing is injected, to inherit as before.
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, injected in injected }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", stderr: String(describing: error), status: -1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }
}
