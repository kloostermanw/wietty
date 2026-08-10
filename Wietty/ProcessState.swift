import Foundation

/// Runtime state of a managed process.
enum ProcessState: Equatable {
    case idle        // never started, stopped cleanly, or cleared
    case starting    // spawn in progress
    case running     // foreground process alive, or daemon up
    case finished    // exited with status 0
    case failed(Int32) // exited non-zero (crash / test failure); associated exit code
    case stopping    // stop requested, shutdown in progress
    case orphaned    // still running, but its definition was removed from config
}

enum ProcessDotFill { case filled, open }
enum ProcessDotColor { case green, red, gray }

/// The status dot's two independent axes: fill = liveness, color = outcome.
struct ProcessDot: Equatable {
    let fill: ProcessDotFill
    let color: ProcessDotColor
}

/// Maps a process state to its status dot. Filled = running; color green =
/// success/healthy, red = failed/crashed, gray = neutral.
func processDot(for state: ProcessState) -> ProcessDot {
    switch state {
    case .running, .orphaned, .stopping:
        return ProcessDot(fill: .filled, color: .green)
    case .finished:
        return ProcessDot(fill: .open, color: .green)
    case .failed:
        return ProcessDot(fill: .open, color: .red)
    case .idle, .starting:
        return ProcessDot(fill: .open, color: .gray)
    }
}

/// Whether a process should be treated as running for the row's hover actions.
/// Running (stop + refresh shown) while it is up or transitioning
/// (`.starting`/`.stopping`) and while `.orphaned` (still alive, just dropped
/// from config); not running (play shown) once it is `.idle`/`.finished`/`.failed`.
func processIsRunning(for state: ProcessState) -> Bool {
    switch state {
    case .running, .starting, .stopping, .orphaned:
        return true
    case .idle, .finished, .failed:
        return false
    }
}
