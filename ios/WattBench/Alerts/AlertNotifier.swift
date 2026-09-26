import UIKit
import UserNotifications

/// Notification permission as the Alerts screen shows it.
enum NotificationAuthorization: Equatable {
    case notDetermined, authorized, denied
}

/// One local notification the coordinator wants delivered.
struct AlertNotification: Equatable {
    enum Category: String {
        /// A rule fired outside a recording.
        case alert
        /// A rule fired during a recording: offers "Stop & save".
        case recordingAlert
        /// Recording finished / interrupted notices.
        case recordingNotice
        /// The "Send test notification" button; shown even in the foreground.
        case test
    }

    var identifier: String
    var category: Category
    var title = "WattBench"
    var subtitle = ""
    var body: String
    /// Seconds until delivery; 0 delivers at once.
    var delay: TimeInterval = 0
}

/// What `AlertCoordinator` needs from the notification layer; mocked in tests.
@MainActor
protocol AlertNotifying: AnyObject {
    /// True while the app is in the foreground (banner instead of notification).
    var isAppActive: Bool { get }
    /// Invoked for the notification's "Stop & save" action.
    var onStopAndSave: (@MainActor () -> Void)? { get set }
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    /// Schedules (or, for a pending identifier, replaces) a notification.
    func post(_ notification: AlertNotification)
    func cancelPending(identifier: String)
}

/// `UNUserNotificationCenter` front end. Registers the notification
/// categories and installs itself as the center's delegate when created,
/// which happens inside `WattBenchApp.init` (before the app finishes
/// launching, as the delegate must be).
///
/// Delivery policy: alerts use the in-app banner while the app is in front
/// (`.active` or `.inactive`), so `willPresent` suppresses every system
/// banner except the test one, and except when the app is `.inactive`, where
/// a pending notification (the disconnect dead man's switch) landing behind
/// Control Center or the app switcher would otherwise be dropped silently;
/// the "Stop & save" action is forwarded to `onStopAndSave` on the main
/// actor. Interruption level is `.active` (no time-sensitive entitlement).
@MainActor
final class AlertNotifier: NSObject, AlertNotifying {
    nonisolated static let stopAndSaveAction = "wattbench.stopAndSave"
    nonisolated static let threadIdentifier = "wattbench.alerts"

    var onStopAndSave: (@MainActor () -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    /// Only `.background` counts as "not in front": while the app is merely
    /// `.inactive` (Control Center, the app switcher, an incoming call) its
    /// window is still on screen, so the in-app banner is the right delivery
    /// and a system notification would only be suppressed by `willPresent`.
    var isAppActive: Bool {
        UIApplication.shared.applicationState != .background
    }

    func authorizationStatus() async -> NotificationAuthorization {
        Self.map(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .authorized : .denied
    }

    func post(_ n: AlertNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.subtitle = n.subtitle
        content.body = n.body
        content.sound = .default
        content.categoryIdentifier = n.category.rawValue
        content.threadIdentifier = Self.threadIdentifier
        content.interruptionLevel = .active
        let trigger = n.delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: n.delay, repeats: false) : nil
        center.add(UNNotificationRequest(identifier: n.identifier, content: content, trigger: trigger)) { _ in }
    }

    func cancelPending(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Internals

    private func registerCategories() {
        let stop = UNNotificationAction(identifier: Self.stopAndSaveAction, title: "Stop & save", options: [])
        var categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: AlertNotification.Category.recordingAlert.rawValue,
                                   actions: [stop], intentIdentifiers: [], options: []),
        ]
        for plain in [AlertNotification.Category.alert, .recordingNotice, .test] {
            categories.insert(UNNotificationCategory(identifier: plain.rawValue, actions: [],
                                                     intentIdentifiers: [], options: []))
        }
        center.setNotificationCategories(categories)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
// The center does not promise a queue, so these hop to the main actor. The
// completion handlers are plain (non-Sendable) closures the system hands us;
// calling them from the main queue is fine, so the capture is marked as such.

extension AlertNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isTest = notification.request.content.categoryIdentifier == AlertNotification.Category.test.rawValue
        if isTest {
            completionHandler([.banner, .list, .sound])
            return
        }
        nonisolated(unsafe) let finish = completionHandler
        DispatchQueue.main.async {
            // In front: the in-app banner is the delivery. Behind Control Center
            // or the app switcher (`.inactive`) nothing of ours is visible, so show it.
            let inactive = MainActor.assumeIsolated { UIApplication.shared.applicationState == .inactive }
            finish(inactive ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isStopAndSave = response.actionIdentifier == Self.stopAndSaveAction
        nonisolated(unsafe) let finish = completionHandler
        DispatchQueue.main.async {
            if isStopAndSave {
                MainActor.assumeIsolated { self.onStopAndSave?() }
            }
            finish()
        }
    }
}
