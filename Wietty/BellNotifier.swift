import Foundation
import UserNotifications

/// Whether this app may post, as far as it can tell without asking.
///
/// A type of this app's own rather than `UNAuthorizationStatus`, because the
/// settings tab asks a narrower question than the system's five cases answer: may
/// we post, may we ask, or is neither true. `provisional` and `ephemeral` both post
/// without a prompt, so they land on `granted`.
enum NotificationPermission: Equatable {
    /// Nobody has been asked yet, so the tab can offer a button that asks.
    case notAsked
    case granted
    /// Asking again does nothing: only System Settings can undo this.
    case denied
}

/// The only things this app asks of a notification centre.
///
/// A protocol so the posting rules can be tested without the real
/// `UNUserNotificationCenter`, which needs an authorized bundle and would put a
/// permission prompt on screen during a test run.
@MainActor
protocol NotificationSink: AnyObject {
    /// Asks for permission, or reports what was already decided.
    func requestAuthorization() async -> Bool
    /// What was decided already, without asking. Never prompts, so the settings tab
    /// can show the state without one appearing because a panel was opened.
    func authorizationStatus() async -> NotificationPermission
    /// Throws whatever the centre refused with. The bell path swallows it, because
    /// an alert about a failed notification is an interruption complaining about an
    /// interruption; the Test button in Settings is the one caller that shows it.
    func add(_ notification: BellNotification) async throws
    func removeDelivered(identifiers: [String])
    /// Called when the user taps a notification. Set by whoever knows how to show a
    /// terminal, which is `ContentView`.
    var onTap: (@MainActor (BellTarget) -> Void)? { get set }
}

/// Posts one notification per bell, and asks for permission the first time rather
/// than at launch.
///
/// Launch is the wrong moment: a permission prompt in front of someone who has not
/// rung a bell yet is a prompt about nothing, and denying it there costs the
/// feature for good. The first bell is the moment the request explains itself.
@MainActor
final class BellNotifier {
    private let sink: NotificationSink
    /// Nil until the answer is known. Cached because `requestAuthorization` shows a
    /// prompt only once but is not free, and because a denied user must not be asked
    /// again on every bell.
    private var granted: Bool?
    /// The in flight request, so several bells arriving together await one answer
    /// instead of racing to ask.
    private var request: Task<Bool, Never>?

    init(sink: NotificationSink) {
        self.sink = sink
    }

    var onTap: (@MainActor (BellTarget) -> Void)? {
        get { sink.onTap }
        set { sink.onTap = newValue }
    }

    func post(_ notification: BellNotification) async {
        guard await authorized() else { return }
        try? await sink.add(notification)
    }

    /// What the centre has already decided, without asking it for anything.
    ///
    /// Reads through to the sink every time rather than answering from `granted`:
    /// permission can be revoked in System Settings while the app runs, and the
    /// settings tab showing a cached "granted" would be the one place that is wrong
    /// about it.
    func permission() async -> NotificationPermission {
        let status = await sink.authorizationStatus()
        // Keep the posting path's cache honest with what was just read, so a
        // permission granted from the settings tab does not leave bells suppressed
        // by a `granted` of false decided at the first bell.
        switch status {
        case .granted: granted = true
        case .denied: granted = false
        case .notAsked: granted = nil
        }
        return status
    }

    /// Asks, from the settings tab's button, and reports what came back.
    ///
    /// The prompt appears once per install: a second call after a denial returns
    /// false without showing anything, which is why the tab offers the button only
    /// while the answer is `.notAsked`.
    func requestPermission() async -> NotificationPermission {
        _ = await authorized()
        return await permission()
    }

    /// Posts the Test button's notification, and says what went wrong if it did not
    /// arrive.
    ///
    /// Distinct from `post` because this is the one place a failure is worth
    /// showing: the whole point of the button is to find out whether the path works,
    /// and a button that fails silently answers the opposite question.
    func sendTest(sound: BellSound) async -> TestResult {
        guard await authorized() else {
            return .failed(reason: await permission() == .denied
                           ? "Notifications are turned off for Wietty in System Settings."
                           : "Wietty was not allowed to post notifications.")
        }
        do {
            try await sink.add(.test(sound: sound))
            return .posted
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// What the Test button has to say afterwards.
    enum TestResult: Equatable {
        case posted
        case failed(reason: String)
    }

    /// Takes notifications back out of Notification Center, for bells that have been
    /// dealt with.
    ///
    /// Never asks for permission. Withdrawing is not worth a prompt, and asking here
    /// would mean the first thing someone who has never had a bell sees is a request
    /// triggered by them clicking a row.
    func withdraw(_ targets: [BellTarget]) {
        guard granted == true, !targets.isEmpty else { return }
        sink.removeDelivered(identifiers: targets.map(\.notificationIdentifier))
    }

    private func authorized() async -> Bool {
        if let granted { return granted }
        if let request { return await request.value }
        let task = Task { await sink.requestAuthorization() }
        request = task
        let result = await task.value
        granted = result
        request = nil
        return result
    }
}

/// `UNUserNotificationCenter`, and the delegate it needs.
///
/// Thin on purpose: everything decidable lives in `BellNotification`,
/// `BellAlert` and `BellNotifier`, so what is left here is the part no test can
/// reach anyway.
@MainActor
final class SystemNotificationSink: NSObject, NotificationSink, UNUserNotificationCenterDelegate {
    private let centre = UNUserNotificationCenter.current()
    /// A tap that arrived before anyone was listening.
    ///
    /// Required rather than defensive: tapping a notification can launch the app, and
    /// the system delivers that tap as soon as a delegate exists, which is during
    /// launch and therefore before `ContentView` has run its `task` and set `onTap`.
    /// Without this the one tap that matters most, the one that started the app, is
    /// the one that gets dropped.
    private var pendingTap: BellTarget?

    var onTap: (@MainActor (BellTarget) -> Void)? {
        didSet {
            guard let onTap, let pending = pendingTap else { return }
            pendingTap = nil
            onTap(pending)
        }
    }

    override init() {
        super.init()
        // Set here rather than later because of `pendingTap` above: the delegate has
        // to exist before launch finishes or a tap that launched the app is lost.
        centre.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await centre.requestAuthorization(options: [.alert, .sound])
        } catch {
            // Denied, or a bundle the notification centre refuses. Either way there
            // is nothing to show and nothing to say: the 🔔 in the sidebar is still
            // there, and an alert about a failed notification would be an
            // interruption complaining about an interruption.
            return false
        }
    }

    /// What was decided already. Never prompts: `notificationSettings()` reads the
    /// state, `requestAuthorization` is the one that can put a panel on screen.
    func authorizationStatus() async -> NotificationPermission {
        switch await centre.notificationSettings().authorizationStatus {
        case .notDetermined: return .notAsked
        // Both post without a prompt, so as far as this app is concerned they are
        // permission.
        case .authorized, .provisional, .ephemeral: return .granted
        // `.denied`, and whatever a later macOS adds: anything this build does not
        // recognise is treated as "cannot post", which is the safe way to be wrong.
        default: return .denied
        }
    }

    func add(_ notification: BellNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = notification.sound.notificationSound
        content.userInfo = notification.target.userInfo
        // No trigger: deliver now.
        let request = UNNotificationRequest(identifier: notification.identifier,
                                           content: content, trigger: nil)
        try await centre.add(request)
    }

    func removeDelivered(identifiers: [String]) {
        centre.removeDeliveredNotifications(withIdentifiers: identifiers)
        // Pending as well, for the window between adding a request and it being
        // delivered. A bell dealt with that fast still should not arrive.
        centre.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shows the banner even while Wietty is frontmost, which the system would
    /// otherwise suppress.
    ///
    /// Being frontmost is not the same as looking at the terminal that rang: with the
    /// sidebar in front of you, a bell from another workspace's agent is exactly the
    /// thing you want to be told about. The narrower rule, the one about the terminal
    /// actually on screen, is `BellAlert` and is applied before anything is posted.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        // The whole tap, reduced to a value, before hopping. `UNNotificationResponse`
        // is not `Sendable`, so nothing about it may cross the actor boundary.
        guard let target = BellTarget(userInfo: response.notification.request.content.userInfo) else { return }
        await deliver(target)
    }

    private func deliver(_ target: BellTarget) {
        if let onTap {
            onTap(target)
        } else {
            pendingTap = target
        }
    }
}
