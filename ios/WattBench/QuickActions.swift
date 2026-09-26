import SwiftUI
import UIKit

/// Home Screen quick actions (long-press the app icon). The item types are
/// `AppRouter.QuickAction` raw values, declared in project.yml under
/// `UIApplicationShortcutItems`. A cold launch delivers the item through
/// `configurationForConnecting`; a warm launch through the scene delegate.
/// Both hand it to `router.pendingQuickAction` via `QuickActions`.
enum QuickActions {
    static let didReceive = Notification.Name("com.thebench.wattbench.quickAction")
    /// Set before the SwiftUI scene exists (cold launch); consumed by WattBenchApp.
    @MainActor static var pending: AppRouter.QuickAction?

    @MainActor static func handle(_ item: UIApplicationShortcutItem) {
        guard let action = AppRouter.QuickAction(rawValue: item.type) else { return }
        pending = action
        NotificationCenter.default.post(name: didReceive, object: action)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            QuickActions.handle(item)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        QuickActions.handle(shortcutItem)
        completionHandler(true)
    }
}
