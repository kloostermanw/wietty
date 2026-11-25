import Foundation
import Darwin

/// Why a local socket path could not be used or bound.
package enum LocalSocketError: Error, Equatable {
    case socketPathTooLong(String)
    /// A socket path that is not absolute.
    case relativeSocketPath(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// A listening Unix socket whose file only this user can reach, shared by the local
/// stream server and the pane's bridge.
package enum PrivateSocket {
    /// Which file a socket was bound as: an owner unlinks only that file, and not one
    /// another process has put at the path since.
    package typealias Identity = (device: dev_t, inode: ino_t)

    /// The name `mkdtemp` makes the private bind directory from, next to the socket.
    /// `LocalSocketPaths.sweep` removes one a crash left behind.
    package static let directoryPrefix = ".wty-"
    static let directoryTemplate = directoryPrefix + "XXXXXX"
    /// What is bound inside the private directory.
    static let boundName = "s"

    /// Throws unless `path` is absolute and both it and the bind path made for it fit
    /// `sun_path`. A relative path would put the private directory's template at the
    /// root of the filesystem, and a path that fits while its bind path does not
    /// would fail only when it is bound.
    package static func check(_ path: String) throws {
        guard path.hasPrefix("/") else { throw LocalSocketError.relativeSocketPath(path) }
        guard path.utf8.count < LocalSocketPaths.sunPathLimit else {
            throw LocalSocketError.socketPathTooLong(path)
        }
        let bindPath = template(for: path) + "/" + boundName
        guard bindPath.utf8.count < LocalSocketPaths.sunPathLimit else {
            throw LocalSocketError.socketPathTooLong(bindPath)
        }
    }

    private static func template(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return (directory.hasSuffix("/") ? directory : directory + "/") + directoryTemplate
    }

    /// Binds and listens at `path`, with the socket file never reachable by anyone else,
    /// and returns the listening descriptor (`FD_CLOEXEC`, `SO_NOSIGPIPE` and
    /// `O_NONBLOCK`, so it can be accepted from on a dispatch source) and the file's
    /// identity.
    ///
    /// The mode of a socket file comes from the umask at `bind`, which is process
    /// wide, and `fchmod` does not reach the file of a socket (EINVAL on macOS). So the
    /// socket is bound inside a fresh directory of mode 0700 next to `path`
    /// (`mkdtemp`), set to 0600 there, listened on, and only then renamed onto `path`,
    /// which also replaces a stale file atomically. While its mode is wider, nobody but
    /// this user can reach it, because nobody else can enter the directory; and from
    /// the moment it has its public name a `connect` finds a listener.
    package static func listen(at path: String, backlog: Int32) throws -> (fd: Int32, identity: Identity) {
        try check(path)
        var template = Array(template(for: path).utf8CString)
        guard let made = mkdtemp(&template) else { throw LocalSocketError.bindFailed(errno) }
        let privateDirectory = String(cString: made)
        defer { rmdir(privateDirectory) }
        let bindPath = privateDirectory + "/" + boundName

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalSocketError.socketFailed(errno) }
        func fail(_ error: (Int32) -> LocalSocketError) -> LocalSocketError {
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
        guard bound == 0 else { throw fail(LocalSocketError.bindFailed) }
        guard chmod(bindPath, 0o600) == 0 else { throw fail(LocalSocketError.bindFailed) }
        // Taken before the rename, which keeps the inode, and from the file itself
        // (`lstat`): without it `stop` could not recognise its own socket.
        var info = stat()
        guard lstat(bindPath, &info) == 0 else { throw fail(LocalSocketError.bindFailed) }
        // Accepting runs on a dispatch source and must never block on a client
        // that went away between being readable and being accepted.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // Listening before the rename: the public name never exists without a listener.
        guard Darwin.listen(fd, backlog) == 0 else { throw fail(LocalSocketError.listenFailed) }
        guard rename(bindPath, path) == 0 else { throw fail(LocalSocketError.bindFailed) }
        return (fd, (info.st_dev, info.st_ino))
    }

    /// Unlinks `path` if it is still the file `identity` names.
    package static func unlink(_ path: String, ifStill identity: Identity) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode {
            Darwin.unlink(path)
        }
    }
}
