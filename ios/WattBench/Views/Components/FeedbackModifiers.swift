import SwiftUI

// The app's haptic and motion vocabulary. Haptics are keyed on model event
// counters (never per sample) so they fire exactly once per connect, error,
// record start/stop, save and trip reset, and they are no-ops while
// `Preferences.hapticsEnabled` is off. Symbol effects and rolling digits are
// disabled under Reduce Motion.

extension View {
    /// `.success` once per connection, `.warning` once per error or drop.
    func connectionFeedback(_ meter: MeterManager) -> some View {
        modifier(ConnectionFeedback(meter: meter))
    }

    /// `.start` when a recording begins, `.stop` when it ends.
    func recordingFeedback(_ meter: MeterManager) -> some View {
        modifier(RecordingFeedback(meter: meter))
    }

    /// Light impact once per saved session.
    func saveFeedback(_ store: SessionStore) -> some View {
        modifier(SaveFeedback(store: store))
    }

    /// Light impact once per trip reset.
    func tripResetFeedback(_ meter: MeterManager) -> some View {
        modifier(TripResetFeedback(meter: meter))
    }

    /// `.selection` whenever `value` changes (metric or window switches).
    func selectionFeedback<V: Equatable>(on value: V) -> some View {
        modifier(SelectionFeedback(value: value))
    }

    /// Rolling digits: `numericText` content transition plus a snappy
    /// animation keyed on `value`, both off under Reduce Motion. Pair with
    /// `.monospacedDigit()` on the text.
    func rollingNumber(_ value: Double) -> some View {
        modifier(RollingNumber(value: value))
    }

    /// `symbolEffect(_:isActive:)` that stays inert under Reduce Motion.
    func symbolEffectRespectingMotion<E: IndefiniteSymbolEffect & SymbolEffect>(_ effect: E, isActive: Bool = true) -> some View {
        modifier(MotionIndefiniteSymbolEffect(effect: effect, isActive: isActive))
    }

    /// `symbolEffect(_:value:)` (bounce once on connect, for example) that
    /// stays inert under Reduce Motion.
    func symbolEffectRespectingMotion<E: DiscreteSymbolEffect & SymbolEffect, V: Equatable>(_ effect: E, value: V) -> some View {
        modifier(MotionDiscreteSymbolEffect(effect: effect, value: value))
    }
}

// MARK: - Haptics
// Each modifier reads the haptics switch from `Preferences` in the
// environment; previews and tests may omit it, in which case haptics stay on.

struct ConnectionFeedback: ViewModifier {
    let meter: MeterManager
    @Environment(Preferences.self) private var prefs: Preferences?

    func body(content: Content) -> some View {
        let on = prefs?.hapticsEnabled ?? true
        content
            .sensoryFeedback(trigger: meter.connectionEventCount) { _, _ in on ? .success : nil }
            .sensoryFeedback(trigger: meter.errorEventCount) { _, _ in on ? .warning : nil }
    }
}

struct RecordingFeedback: ViewModifier {
    let meter: MeterManager
    @Environment(Preferences.self) private var prefs: Preferences?

    func body(content: Content) -> some View {
        let on = prefs?.hapticsEnabled ?? true
        let isRecording = meter.recording != nil
        content.sensoryFeedback(trigger: meter.recordingEventCount) { _, _ in
            guard on else { return nil }
            return isRecording ? .start : .stop
        }
    }
}

struct SaveFeedback: ViewModifier {
    let store: SessionStore
    @Environment(Preferences.self) private var prefs: Preferences?

    func body(content: Content) -> some View {
        let on = prefs?.hapticsEnabled ?? true
        content.sensoryFeedback(trigger: store.saveCount) { _, _ in on ? .impact(weight: .light) : nil }
    }
}

struct TripResetFeedback: ViewModifier {
    let meter: MeterManager
    @Environment(Preferences.self) private var prefs: Preferences?

    func body(content: Content) -> some View {
        let on = prefs?.hapticsEnabled ?? true
        content.sensoryFeedback(trigger: meter.tripResetCount) { _, _ in on ? .impact(weight: .light) : nil }
    }
}

struct SelectionFeedback<V: Equatable>: ViewModifier {
    let value: V
    @Environment(Preferences.self) private var prefs: Preferences?

    func body(content: Content) -> some View {
        let on = prefs?.hapticsEnabled ?? true
        content.sensoryFeedback(trigger: value) { _, _ in on ? .selection : nil }
    }
}

// MARK: - Motion

struct RollingNumber: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText(value: value))
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
    }
}

struct MotionIndefiniteSymbolEffect<E: IndefiniteSymbolEffect & SymbolEffect>: ViewModifier {
    let effect: E
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(effect, isActive: isActive && !reduceMotion)
    }
}

struct MotionDiscreteSymbolEffect<E: DiscreteSymbolEffect & SymbolEffect, V: Equatable>: ViewModifier {
    let effect: E
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(effect, value: value)
        }
    }
}
