import Foundation

/// The boundary between the core and the frontend, and the one thing in this target
/// that exists only to prove it holds.
///
/// `WiettyCore` is everything Wietty does that needs no window: the store, the
/// terminal byte path, the supervisors and the servers. The split is not for reuse,
/// it is so the compiler refuses an import of SwiftUI or AppKit on this side, years
/// before the server becomes its own process (issue #84, phase 5).
///
/// `package` rather than `public` throughout this target. The app and the test
/// bundle share a `SWIFT_PACKAGE_NAME` with it, so they see these declarations while
/// nothing outside the three does. That keeps an internal refactor internal: a
/// hundred members of `ProjectStore` reach the views without any of them becoming
/// published API.
package enum CoreBoundary {
    /// Read from the app and from the test bundle, which is the whole job: it
    /// compiles only while `package` access reaches both of them.
    package static let moduleName = "WiettyCore"
}
