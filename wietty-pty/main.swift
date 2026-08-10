import Foundation
import Darwin

// The Wietty terminal helper.
//
// libghostty spawns and owns its own child and offers no way to feed it bytes, so
// Wietty runs this as the surface's command. It connects to the unix socket
// Wietty listens on and copies bytes between that socket and its own standard
// input and output, which are the pty libghostty rendered.
//
// It interprets nothing. Ghostty's VT is the only VT in the path, and the inner
// pty Wietty owns is the only line discipline, so anything this program did to
// the stream would be wrong twice.
//
// Window size is deliberately not reported from here. Wietty reads the surface
// geometry from libghostty and resizes its own pty directly, which keeps this
// socket a plain byte pipe and this program free of signal handling.
//
// Exit statuses are meaningful, because the surface shows them: 64 for usage, 69
// for a socket nobody is listening on (the terminal is already gone), 70 for a
// socket that could not be created at all.

// A write to either the socket or standard output can land on a peer that is
// already gone: Wietty closes the socket when the terminal is torn down, and
// whatever holds the read end of our stdout (a pipe in tests, the surface's pty
// in the app) can go away first too. The default disposition of SIGPIPE is to
// terminate the process, which would make this helper crash on exactly the
// condition it exists to report cleanly. `pump` already treats a failed write as
// "the peer is gone" and exits 0, so the signal itself is the only thing that
// needs silencing; SO_NOSIGPIPE would only cover the socket half, since standard
// output is not always a socket, so SIGPIPE is ignored process wide instead.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: wietty-pty <socket-path>\n".utf8))
    exit(64)
}
let path = arguments[1]

// Raw mode on our own tty. The inner pty Wietty owns has its own line
// discipline, so leaving this one enabled echoes every keystroke twice and
// translates carriage returns before the shell ever sees them.
var attributes = termios()
if tcgetattr(0, &attributes) == 0 {
    var raw = attributes
    cfmakeraw(&raw)
    tcsetattr(0, TCSANOW, &raw)
}

let socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketFd >= 0 else { exit(70) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8)
guard pathBytes.count < 104 else {
    FileHandle.standardError.write(Data("wietty-pty: socket path too long\r\n".utf8))
    exit(64)
}
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    FileHandle.standardError.write(Data("Wietty: this terminal is gone.\r\n".utf8))
    exit(69)
}

/// Copies one direction until either end closes.
///
/// Either direction ending means the terminal is over: Wietty closed the
/// socket, or libghostty tore the surface down. So the first pump to finish exits
/// the process and takes the other with it, rather than leaving a half connected
/// helper alive holding a pty.
///
/// A read or write that is interrupted by a signal returns -1 with `EINTR` and
/// has moved zero bytes; that is not the peer going away; it is retried rather
/// than read as a hangup, or a stray signal could kill a perfectly healthy
/// helper.
func pump(from source: Int32, to destination: Int32) {
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { exit(0) }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(destination, $0.baseAddress! + offset, count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { exit(0) }
                offset += written
            }
        }
    }
}

pump(from: 0, to: socketFd)          // keystrokes: our tty, which Ghostty owns, to Wietty
pump(from: socketFd, to: 1)          // output: Wietty to our tty, which Ghostty renders
dispatchMain()
