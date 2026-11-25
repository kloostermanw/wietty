import Foundation
import Darwin

/// A listening Unix socket whose file only this user can reach, shared by the local
/// stream server and the pane's bridge.
package enum PrivateSocket {
    /// Binds and listens at `path`, with the socket file never reachable by anyone else,
    /// and returns the listening descriptor: `FD_CLOEXEC`, `SO_NOSIGPIPE` and
    /// `O_NONBLOCK`, so it can be accepted from on a dispatch source.
    ///
    /// The mode of a socket file comes from the umask at `bind`, which is process
    /// wide, and `fchmod` does not reach the file of a socket. So the socket is
    /// bound inside a fresh directory of mode 0700 next to `path` (`mkdtemp`), set
    /// to 0600 there, and only then renamed onto `path`, which also replaces a
    /// stale file atomically. While its mode is wider, nobody but this user can
    /// reach it, because nobody else can enter the directory.
    package static func listen(at path: String, backlog: Int32) throws -> Int32 {
        guard path.utf8.count < LocalSocketPaths.sunPathLimit else {
            throw TerminalRelayError.socketPathTooLong(path)
        }
        let directory = (path as NSString).deletingLastPathComponent
        var template = Array((directory + "/.wty-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw TerminalRelayError.bindFailed(errno) }
        let privateDirectory = String(cString: made)
        defer { rmdir(privateDirectory) }
        let bindPath = privateDirectory + "/s"
        guard bindPath.utf8.count < LocalSocketPaths.sunPathLimit else {
            throw TerminalRelayError.socketPathTooLong(bindPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalRelayError.socketFailed(errno) }
        func fail(_ error: (Int32) -> TerminalRelayError) -> TerminalRelayError {
            let code = errno
            close(fd)
            Darwin.unlink(bindPath)
            return error(code)
        }
        // macOS has no SOCK_CLOEXEC, so this follows the socket call as closely as
        // it can: a child spawned in between would inherit the listener.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var suppressSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(bindPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw fail(TerminalRelayError.bindFailed) }
        guard chmod(bindPath, 0o600) == 0 else { throw fail(TerminalRelayError.bindFailed) }
        guard rename(bindPath, path) == 0 else { throw fail(TerminalRelayError.bindFailed) }
        // Accepting runs on a dispatch source and must never block on a client
        // that went away between being readable and being accepted.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        guard Darwin.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            Darwin.unlink(path)
            throw TerminalRelayError.listenFailed(code)
        }
        return fd
    }

    /// The device and inode of the file at `path`, so an owner can later unlink only
    /// the file it bound and not one another process has put at the path since.
    package static func identity(of path: String) -> (device: dev_t, inode: ino_t) {
        var info = stat()
        stat(path, &info)
        return (info.st_dev, info.st_ino)
    }

    /// Unlinks `path` if it is still the file `identity` names.
    package static func unlink(_ path: String, ifStill identity: (device: dev_t, inode: ino_t)) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode {
            Darwin.unlink(path)
        }
    }
}
