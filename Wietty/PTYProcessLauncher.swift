import Foundation
import Darwin

/// Launches shell commands under a pseudo-terminal via `posix_spawn`, placing the
/// child in its own process group so signals reach the whole tree. Output from
/// the pty master is streamed to `onOutput`; termination is reaped on a
/// background thread and reported via `onExit`. Callbacks are hopped to the main
/// actor.
struct PTYProcessLauncher: ProcessLaunching {
    /// Opt out of the test-host refusal below. Only this type's own suite should set
    /// it, and only with commands it wrote itself: it is the one place that has to
    /// reach a real shell to have anything to assert on.
    private let spawnsFromTestHost: Bool

    init(spawnsFromTestHost: Bool = false) {
        self.spawnsFromTestHost = spawnsFromTestHost
    }

    /// Login shell used to run commands, so PATH and shell setup match a terminal.
    private var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// True when this process is a test host rather than the app.
    ///
    /// `ProjectStore` defaults both of its supervisors to a real launcher, so a test
    /// that builds a store without injecting a fake gets this type, and applying a
    /// definition with `auto_start` launches for real, in a login shell, with the
    /// developer's own `HOME`. A fixture command written to look dangerous then is
    /// dangerous. This is the backstop that keeps the default from being a live one:
    /// tests that genuinely exercise launching inject `FakeProcessLauncher`.
    ///
    /// The signals are read together because the suite is Swift Testing rather than
    /// XCTest: `XCTestConfigurationFilePath` is set by `xcodebuild test`, and the
    /// loaded-class check still holds when a bundle is run some other way.
    static var isRunningInTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest") != nil
    }

    func launch(
        command: String,
        directory: URL,
        environment: [String: String],
        onOutput: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> ProcessHandle {
        // 0. Never reach a real shell from a test host unless asked to explicitly.
        guard spawnsFromTestHost || !Self.isRunningInTestHost else {
            throw ProcessLaunchError.spawnRefusedInTestHost
        }

        // 1. Allocate a pty pair.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slavePath = ptsname(master) else {
            if master >= 0 { close(master) }
            throw ProcessLaunchError.ptyAllocationFailed
        }
        let slave = open(slavePath, O_RDWR)
        guard slave >= 0 else { close(master); throw ProcessLaunchError.ptyAllocationFailed }

        // 2. File actions: child's stdin/out/err = slave; close master in child.
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)

        // 3. Spawn attrs: new process group (leader), so killpg targets the tree.
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        // 4. Build argv: `<shell> -l -c "cd <dir> && (command)"`.
        let fullCommand = "cd \(shellQuote(directory.path)) && (\(command))"
        let argv = [shell, "-l", "-c", fullCommand]
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]

        // 5. Environment: inherit + overrides + TERM.
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in environment { mergedEnv[k] = v }
        if mergedEnv["TERM"] == nil { mergedEnv["TERM"] = "xterm-256color" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = mergedEnv.map { strdup("\($0)=\($1)") } + [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, shell, &actions, &attr, cArgv, cEnv)

        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        cArgv.forEach { free($0) }
        cEnv.forEach { free($0) }
        close(slave) // parent does not use the slave

        guard rc == 0 else { close(master); throw ProcessLaunchError.spawnFailed(rc) }

        // 6. Stream the master fd.
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .utility))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(master, &buffer, buffer.count)
            if n > 0 {
                let text = String(decoding: buffer[0..<n], as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { onOutput(text) } }
            } else {
                source.cancel()
            }
        }
        source.setCancelHandler { close(master) }
        source.resume()

        // 7. Reap the child on a background thread and report exit.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(code) } }
        }

        return PTYHandle(pid: pid)
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ProcessLaunchError: Error, Equatable {
    case ptyAllocationFailed
    case spawnFailed(Int32)
    /// A real spawn was attempted from a test host. See `PTYProcessLauncher.isRunningInTestHost`.
    case spawnRefusedInTestHost
}

/// Signals the child's process group so the whole subtree is targeted.
final class PTYHandle: ProcessHandle, @unchecked Sendable {
    private let pid: pid_t
    init(pid: pid_t) { self.pid = pid }
    func send(signal: Int32) { killpg(pid, signal) }
}
