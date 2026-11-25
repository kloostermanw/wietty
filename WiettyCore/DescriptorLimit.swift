import Darwin
import Foundation

/// The process's open descriptor limit, raised at launch.
///
/// An app launched from the Finder gets a soft `RLIMIT_NOFILE` of 256. Each live local
/// terminal costs the app four descriptors (its pty's master, the socket its bridge
/// accepted from the helper, its link's socket and the server's end of it) plus what
/// libghostty's surface holds, so a few dozen terminals reach 256 and the next one
/// fails to open or shows a blank pane. So the app raises the soft limit at launch,
/// before any terminal exists.
package enum DescriptorLimit {
    /// What the app asks for. Far above what a person's terminals need, and small
    /// enough that a spawned child closing every inherited descriptor up to it
    /// (`RawPTY.spawn`) costs about a millisecond.
    package static let target: rlim_t = 8192

    /// The soft limits to try, in order, to raise `soft` to `min(hard, cap)`, or
    /// none when `soft` is already there.
    ///
    /// macOS refuses (`EINVAL`) a soft limit above `kern.maxfilesperproc`, even when
    /// the hard limit is `RLIM_INFINITY`, so that is the first clamp when it is
    /// known; `OPEN_MAX` follows as a value that is always accepted on the systems
    /// this runs on, then halvings, so a refused value falls back to a lower one
    /// rather than leaving the limit where it was. Every candidate is above `soft`.
    package static func candidates(soft: rlim_t, hard: rlim_t, cap: rlim_t = target,
                                   perProcess: rlim_t?) -> [rlim_t] {
        var wanted = min(hard, cap)
        if let perProcess { wanted = min(wanted, perProcess) }
        guard wanted > soft else { return [] }
        var values: [rlim_t] = [wanted]
        let openMax = rlim_t(OPEN_MAX)
        if openMax < wanted, openMax > soft { values.append(openMax) }
        var next = (values.last ?? wanted) / 2
        while next > soft {
            values.append(next)
            next /= 2
        }
        return values
    }

    /// `kern.maxfilesperproc`, or nil when it cannot be read.
    package static func perProcessMaximum() -> rlim_t? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0, value > 0 else {
            return nil
        }
        return rlim_t(value)
    }

    /// Raises the soft limit as `candidates` says, and returns the soft limit in force
    /// afterwards (and before, for the log). Leaves the hard limit alone.
    @discardableResult
    package static func raise(cap: rlim_t = target) -> (before: rlim_t, after: rlim_t) {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return (0, 0) }
        let before = limits.rlim_cur
        for value in candidates(soft: before, hard: limits.rlim_max, cap: cap,
                                perProcess: perProcessMaximum()) {
            var wanted = limits
            wanted.rlim_cur = value
            if setrlimit(RLIMIT_NOFILE, &wanted) == 0 { return (before, value) }
        }
        return (before, before)
    }
}
