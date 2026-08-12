import Foundation
@testable import Wietty

/// A notification centre that records what it was asked to do.
///
/// Shared rather than private to one suite because two need it: the posting rules
/// are asserted against it, and every render of the Settings panel needs a notifier
/// that is not the real `UNUserNotificationCenter`. The real one needs an authorized
/// bundle and would put a permission prompt on screen during a test run.
@MainActor
final class FakeNotificationSink: NotificationSink {
    var granted = true
    /// What the centre would report without being asked. Follows `granted` by
    /// default; set it to model a permission the user changed elsewhere.
    var status: NotificationPermission?
    /// What the centre refuses with, for the one caller that shows the failure.
    var addFailure: (any Error)?
    var authorizationRequests = 0
    var statusReads = 0
    var added: [BellNotification] = []
    var withdrawn: [[String]] = []
    var onTap: (@MainActor (BellTarget) -> Void)?

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return granted
    }

    func authorizationStatus() async -> NotificationPermission {
        statusReads += 1
        return status ?? (granted ? .granted : .denied)
    }

    func add(_ notification: BellNotification) async throws {
        if let addFailure { throw addFailure }
        added.append(notification)
    }

    func removeDelivered(identifiers: [String]) { withdrawn.append(identifiers) }
}

/// What a notification centre that refuses the bundle says, which is the failure
/// the Test button in Settings exists to surface.
struct FakeSinkRefusal: LocalizedError {
    var errorDescription: String? { "Notifications are not allowed for this application" }
}
