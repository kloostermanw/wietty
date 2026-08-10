import Testing
import Foundation

/// Where `wietty-pty` is at runtime, resolved the way the app resolves it, so a
/// bundling mistake fails at the first test that launches the helper rather than
/// at the first terminal a user opens.
///
/// Shared rather than copied per suite: `WiettyPtyHelperTests` exercises the
/// helper on its own and `RelayHelperIntegrationTests` runs it against a real
/// relay, and two copies of this lookup would drift the day the bundling changes.
func bundledHelperURL() throws -> URL {
    // In the test bundle the app under test is the host, so its auxiliary
    // executables are reachable through the host bundle.
    if let url = Bundle.main.url(forAuxiliaryExecutable: "wietty-pty") { return url }
    let host = Bundle.allBundles.compactMap {
        $0.url(forAuxiliaryExecutable: "wietty-pty")
    }.first
    return try #require(host)
}
