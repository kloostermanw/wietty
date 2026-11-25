import Darwin
import Foundation
import Testing
import WiettyCore

/// The open descriptor limit the app raises at launch.
@Suite struct DescriptorLimitTests {
    /// `RLIM_INFINITY`, which Swift does not import: the largest value, as on Darwin.
    private let infinity = rlim_t.max >> 1
    /// The Finder's 256 is raised to the target, clamped by the hard limit and by
    /// `kern.maxfilesperproc`, with lower values to fall back to.
    @Test func aFinderLaunchIsRaisedToTheTarget() {
        let values = DescriptorLimit.candidates(soft: 256, hard: infinity, perProcess: 61440)
        #expect(values.first == 8192)
        #expect(values == [8192, 4096, 2048, 1024, 512])
    }

    @Test func theHardLimitAndThePerProcessMaximumClampIt() {
        #expect(DescriptorLimit.candidates(soft: 256, hard: 2000, perProcess: 61440).first == 2000)
        #expect(DescriptorLimit.candidates(soft: 256, hard: infinity, perProcess: 3000).first == 3000)
    }

    /// A per process maximum that cannot be read leaves `OPEN_MAX` as the first
    /// fallback when the target is above it.
    @Test func openMaxIsTheFallbackAboveIt() {
        let values = DescriptorLimit.candidates(soft: 256, hard: infinity, cap: 20000, perProcess: nil)
        #expect(values.prefix(2) == [20000, rlim_t(OPEN_MAX)])
        #expect(values.allSatisfy { $0 > 256 })
    }

    /// A limit already at or above the target is left alone, never lowered.
    @Test func aHigherLimitIsLeftAlone() {
        #expect(DescriptorLimit.candidates(soft: 8192, hard: infinity, perProcess: 61440).isEmpty)
        #expect(DescriptorLimit.candidates(soft: 1 << 20, hard: infinity, perProcess: 61440).isEmpty)
    }

    /// The call itself: the soft limit afterwards is what it reports, never below
    /// where it was, and at least the target where the system allows it.
    @Test func raisingReportsTheLimitInForce() {
        let result = DescriptorLimit.raise()
        var limits = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &limits) == 0)
        #expect(limits.rlim_cur == result.after)
        #expect(result.after >= result.before)
        #expect(result.after >= min(DescriptorLimit.target, limits.rlim_max))
    }
}
