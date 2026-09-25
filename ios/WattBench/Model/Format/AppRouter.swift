import Foundation
import Observation

/// Cross-tab navigation state (which tab is shown, the Sessions stack).
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable { case live, sessions }

    var tab: Tab = .live
    var sessionPath: [UUID] = []
}
