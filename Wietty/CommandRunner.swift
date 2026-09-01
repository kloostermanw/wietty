import Foundation

struct CommandResult: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var status: Int32
}

protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
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
