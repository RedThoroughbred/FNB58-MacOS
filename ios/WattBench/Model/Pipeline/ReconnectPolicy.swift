import Foundation

/// Backoff schedule and give-up horizon for reconnect attempts.
///
/// With `bluetooth-central`, the actual reconnect is a pending
/// `CBCentralManager.connect` that CoreBluetooth completes whenever the meter
/// reappears (also in the background), so this policy only drives what is
/// DISPLAYED: `.reconnecting` flips to `.unreachable` once `giveUpAfter`
/// seconds have passed without a connection.
struct ReconnectPolicy: Equatable {
    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    static let giveUpAfter: TimeInterval = 120

    var attempt = 0
    var firstFailureAt: Date?

    /// Delay before the next attempt, or nil once `giveUpAfter` seconds have
    /// elapsed since the first failure. Records the first failure on first use.
    mutating func nextDelay(now: Date) -> TimeInterval? {
        let first = firstFailureAt ?? now
        if firstFailureAt == nil { firstFailureAt = now }
        if now.timeIntervalSince(first) >= Self.giveUpAfter { return nil }
        let delay = Self.delays[min(attempt, Self.delays.count - 1)]
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
        firstFailureAt = nil
    }
}
