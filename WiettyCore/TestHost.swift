import Foundation

/// Whether this process is a test bundle's host, and where its settings go when it
/// is.
///
/// The suite runs inside the real app: `WiettyTests` sets `TEST_HOST` to
/// `Wietty.app`, so launching it runs `WiettyApp.init`, builds a `ProjectStore` with
/// default arguments, and that store reads and writes the developer's own
/// `~/.config/wietty/config`. It is not hypothetical that this costs them something:
/// a run during issue #84 deleted a user's sidebar colours, bell sound and sidebar
/// width from that file, and every run strips the session ids of their live
/// terminals through `clearDeadSessions`.
///
/// So under test the defaults move somewhere disposable. Nothing has to remember to
/// inject a fake: the paths that would otherwise reach the user's home resolve
/// inside a per run directory instead, and the `UserDefaults` the legacy migration
/// reads is a throwaway suite rather than the app's own domain.
package enum TestHost {
    /// True when this process was launched to host a test bundle.
    ///
    /// One implementation, read from several places (`PTYProcessLauncher` guards
    /// launching real processes with it). The signals are read together because the
    /// suite is Swift Testing rather than XCTest: `XCTestConfigurationFilePath` is
    /// set by `xcodebuild test`, and the loaded-class check still holds when a
    /// bundle is run some other way.
    package static let isActive: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest") != nil
    }()

    /// The one directory a test host writes into, under the temporary directory.
    ///
    /// A fixed name, emptied as this run starts rather than named uniquely per run.
    /// Unique names are the obvious choice and the wrong one: nothing can be relied on
    /// to remove them, because a test host is routinely killed rather than allowed to
    /// exit, so they accumulate. Clearing a fixed one on the way in gives the same
    /// isolation and leaves at most one behind however the process dies.
    package static let sandbox: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wietty-test-host")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The defaults domain a test host writes into. Fixed, for the reason `sandbox` is.
    package static let defaultsSuiteName = "eu.kloosterman.wietty.test-host"

    /// The `UserDefaults` the app should use: its own domain normally, a throwaway
    /// suite under test.
    ///
    /// Emptied as this run starts, so one run cannot read what another left, and so
    /// `~/Library/Preferences` holds one file rather than one per run. A unique suite
    /// name per run was the first attempt and leaked: every run left its plist behind,
    /// because a test host is killed rather than asked to tidy up after itself.
    /// `nonisolated(unsafe)` because `UserDefaults` carries no `Sendable`
    /// conformance, and this is one instance decided once and then only read.
    /// The app has always shared `UserDefaults.standard` across actors the same way.
    package nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isActive else { return .standard }
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        return UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }()
}
