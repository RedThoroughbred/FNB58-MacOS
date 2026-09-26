import Foundation
import Observation

/// Cross-tab navigation state (which tab is shown, the Sessions stack) and
/// the hand-off point for Home Screen quick actions.
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable { case live, sessions }

    /// Home Screen quick actions (`UIApplicationShortcutItems` in
    /// project.yml). The raw values are the shortcut item types; the app
    /// delegate stores the matching action in `pendingQuickAction` and the
    /// Live tab consumes it.
    enum QuickAction: String, CaseIterable {
        case startRecording = "com.thebench.wattbench.startRecording"
        case connectLastMeter = "com.thebench.wattbench.connectLastMeter"
    }

    var tab: Tab = .live
    var sessionPath: [UUID] = []
    /// Set by the app delegate when the app is launched or activated from a
    /// Home Screen quick action; `ContentView` performs `.connectLastMeter`
    /// itself and switches to Live for `.startRecording`, which the Record
    /// bar takes with `takeQuickAction()`.
    var pendingQuickAction: QuickAction?

    /// Switches to the Live tab (used by the recording chip in Sessions).
    func showLive() {
        tab = .live
    }

    /// Opens one session's detail on the Sessions tab.
    func show(session id: UUID) {
        tab = .sessions
        sessionPath = [id]
    }

    /// Returns and clears the pending quick action when it is `action`.
    @discardableResult
    func takeQuickAction(_ action: QuickAction) -> Bool {
        guard pendingQuickAction == action else { return false }
        pendingQuickAction = nil
        return true
    }
}
