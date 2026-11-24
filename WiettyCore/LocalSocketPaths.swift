import Foundation
import Darwin

/// The names of the local stream sockets, and the sweep of the ones a dead run left.
///
/// Unlike the relay's `ipx-` sockets, these names carry the pid of the process that
/// owns them, so the sweep can tell a socket of a process that is gone from one of a
/// second Wietty running alongside, and need not guess from the file's age.
package enum LocalSocketPaths {
    /// `sockaddr_un.sun_path` is this many bytes, terminator included.
    static let sunPathLimit = 104

    /// `<tmp>/wty-<pid>.sock`
    package static func server(pid: pid_t = getpid(),
                               in directory: String = NSTemporaryDirectory()) throws -> String {
        try fitted(slashed(directory) + "wty-\(pid).sock")
    }

    /// `<tmp>/wty-<pid>-<n>.sock`, for a bridge's raw socket.
    package static func bridge(_ sequence: Int, pid: pid_t = getpid(),
                               in directory: String = NSTemporaryDirectory()) throws -> String {
        try fitted(slashed(directory) + "wty-\(pid)-\(sequence).sock")
    }

    /// Unlinks every `wty-<pid>...sock` whose process no longer exists, and every
    /// `ipx-*.sock` of the old scheme older than an hour. Returns what it removed.
    ///
    /// Only a socket is removed under a `wty-` name, and only one whose name is
    /// exactly one of the two forms above: a file of another kind, a directory and
    /// a symbolic link are left alone (a link is never followed, so nothing outside
    /// `directory` can be reached through one). "No longer exists" is `kill(pid, 0)`
    /// failing with `ESRCH`; a process of another user answers `EPERM` and is alive.
    /// The `ipx-` rule is the one `GhosttyStack.clearStaleSockets` applies.
    @discardableResult
    package static func sweep(in directory: String = NSTemporaryDirectory()) -> [String] {
        let directory = slashed(directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        let cutoff = Date(timeIntervalSinceNow: -GhosttyStack.staleSocketAge)
        var removed: [String] = []
        for name in names.sorted() {
            let path = directory + name
            if let pid = ownerPid(ofName: name) {
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { continue }
                guard kill(pid, 0) == -1, errno == ESRCH else { continue }
                if unlink(path) == 0 { removed.append(path) }
            } else if name.hasPrefix("ipx-"), name.hasSuffix(".sock") {
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                guard let modified = attributes?[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                if unlink(path) == 0 { removed.append(path) }
            }
        }
        return removed
    }

    /// The pid in `wty-<digits>.sock` or `wty-<digits>-<digits>.sock`, nil for any
    /// other name.
    static func ownerPid(ofName name: String) -> pid_t? {
        guard name.hasPrefix("wty-"), name.hasSuffix(".sock") else { return nil }
        let middle = name.dropFirst(4).dropLast(5)
        let parts = middle.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let pid = pid_t(parts[0]), pid > 0 else { return nil }
        if parts.count == 2, Int(parts[1]) == nil { return nil }
        return pid
    }

    private static func slashed(_ directory: String) -> String {
        directory.hasSuffix("/") ? directory : directory + "/"
    }

    /// A path that does not fit has to fail loudly rather than bind a silently
    /// truncated one, as `TerminalRelay.socketPath` explains.
    private static func fitted(_ path: String) throws -> String {
        guard path.utf8.count < sunPathLimit else { throw TerminalRelayError.socketPathTooLong(path) }
        return path
    }
}
