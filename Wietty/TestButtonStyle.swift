import Foundation

/// A test button's outcome color: neutral (never run / stale), passed, failed.
enum TestButtonStyle { case neutral, passed, failed }

/// A test button's full appearance: outcome color plus whether a run is in
/// flight (spinner). Two axes so the view stays a pure function of state,
/// mirroring `ProcessDot`.
struct TestButtonAppearance: Equatable {
    let style: TestButtonStyle
    let running: Bool
}

/// Maps a test runner's `ProcessState` to its button appearance. Passed =
/// `.finished` (green), failed = `.failed` (red), everything else neutral; the
/// spinner shows while starting/running/stopping.
func testButtonAppearance(for state: ProcessState) -> TestButtonAppearance {
    switch state {
    case .finished:
        return TestButtonAppearance(style: .passed, running: false)
    case .failed:
        return TestButtonAppearance(style: .failed, running: false)
    case .starting, .running, .stopping:
        return TestButtonAppearance(style: .neutral, running: true)
    case .idle, .orphaned:
        return TestButtonAppearance(style: .neutral, running: false)
    }
}
