import WiettyCore

/// Compile-time proof that the test bundle sees `package` declarations in
/// `WiettyCore` without `@testable`, because it shares the module's
/// `SWIFT_PACKAGE_NAME`.
///
/// Deliberately not a test case. There is nothing to assert at runtime: either this
/// file compiles, in which case access works, or the build fails and says so. Making
/// it one would also move the suite's count, which is the signal that a file has
/// fallen out of a target. The count is a plain grep for the test attribute, so
/// writing that attribute in a comment moves it too.
let coreBoundaryIsVisibleToTests = CoreBoundary.moduleName
