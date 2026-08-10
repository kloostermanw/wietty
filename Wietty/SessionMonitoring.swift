import Foundation

/// Pushes per-session events (title, bell, job, termination) to the app,
/// whichever substrate they were derived from.
protocol SessionMonitoring: Sendable {
    func start(onEvent: @escaping @MainActor (MonitorEvent) -> Void)
    func stop()
}
