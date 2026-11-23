import Foundation
import WiettyCore

/// Where a test builds its fixtures: a directory inside `TestHost.sandbox`.
///
/// Fixtures used to go straight into the temporary directory under a unique name and
/// most were never removed, which over time left tens of thousands of entries there
/// and made the suite slow. `TestHost.sandbox` is emptied as each run starts, so
/// nothing a test creates under here outlives the next run, however the host died.
/// Use it as a drop in for `FileManager.default.temporaryDirectory`. It exists
/// already, so a test may write a file straight into it.
///
/// Not for Unix socket paths: `sun_path` has a tight length budget, and
/// `GhosttyStack.clearStaleSockets` sweeps `NSTemporaryDirectory()` for exactly those.
enum TestScratch {
    static let root: URL = {
        let url = TestHost.sandbox.appendingPathComponent("scratch")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
