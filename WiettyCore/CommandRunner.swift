import Foundation

package struct CommandResult: Equatable, Sendable {
    package var stdout: String
    package var stderr: String
    package var status: Int32

    /// Spelled out because the implicit memberwise one is internal and the fakes the
    /// store's tests run against are in the other module.
    package init(stdout: String, stderr: String, status: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }
}

package protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) -> CommandResult
}

package struct ProcessCommandRunner: CommandRunning {
    package init() {}

    package func run(_ executable: String, _ arguments: [String], workingDirectory: URL?) -> CommandResult {
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
