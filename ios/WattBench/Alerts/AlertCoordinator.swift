import Foundation
import Observation

/// A threshold rule on one metric. WS-E owns the evaluation.
struct AlertRule: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var metric: Metric
    var above: Double?
    var below: Double?
    var forSeconds: TimeInterval
    var enabled: Bool
    var notify: Bool

    init(id: UUID = UUID(), name: String, metric: Metric, above: Double? = nil, below: Double? = nil,
         forSeconds: TimeInterval = 0, enabled: Bool = true, notify: Bool = false) {
        self.id = id
        self.name = name
        self.metric = metric
        self.above = above
        self.below = below
        self.forSeconds = forSeconds
        self.enabled = enabled
        self.notify = notify
    }
}

/// A fired rule.
struct AlertEvent: Identifiable, Equatable {
    let id: UUID
    let ruleID: UUID
    let title: String
    let message: String
    let firedAt: Date
    let metric: Metric?
    let value: Double?

    init(id: UUID = UUID(), ruleID: UUID, title: String, message: String, firedAt: Date = Date(),
         metric: Metric? = nil, value: Double? = nil) {
        self.id = id
        self.ruleID = ruleID
        self.title = title
        self.message = message
        self.firedAt = firedAt
        self.metric = metric
        self.value = value
    }
}

/// Watches every sample for alert rules and drives banners, haptics and
/// local notifications. Foundation stub: the shape is frozen, `observe` does
/// nothing; WS-E fills in the bodies. `WattBenchApp` wires `onAlert` to
/// `MeterManager.addMarker` and `onStopAndSave` to `MeterManager.stopRecording`.
@MainActor
@Observable
final class AlertCoordinator: SampleObserver {
    var rules: [AlertRule] = []
    private(set) var active: [AlertEvent] = []
    private(set) var alertEventCount = 0

    @ObservationIgnored var onAlert: (@MainActor (AlertEvent) -> Void)?
    @ObservationIgnored var onStopAndSave: (@MainActor () -> Void)?

    init() {}

    func observe(_ r: Reading, context: SampleContext) {
        // WS-E: evaluate `rules` against `r` with hysteresis and cooldown.
    }

    func dismiss(_ id: UUID) {
        active.removeAll { $0.id == id }
    }

    func setEnabled(_ id: UUID, _ on: Bool) async {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = on
    }
}
