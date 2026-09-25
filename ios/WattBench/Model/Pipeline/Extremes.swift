import Foundation

/// Peak-hold values with the time they occurred, since the last reset.
struct Extremes: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var value: Double
        var at: Date
    }

    var maxV: Sample?
    var minV: Sample?
    var maxI: Sample?
    var minI: Sample?
    var maxW: Sample?
    var since: Date

    init(since: Date = Date()) {
        self.since = since
    }

    mutating func update(_ r: Reading) {
        if maxV.map({ r.voltage > $0.value }) ?? true { maxV = Sample(value: r.voltage, at: r.timestamp) }
        if minV.map({ r.voltage < $0.value }) ?? true { minV = Sample(value: r.voltage, at: r.timestamp) }
        if maxI.map({ r.current > $0.value }) ?? true { maxI = Sample(value: r.current, at: r.timestamp) }
        if minI.map({ r.current < $0.value }) ?? true { minI = Sample(value: r.current, at: r.timestamp) }
        if maxW.map({ r.power > $0.value }) ?? true { maxW = Sample(value: r.power, at: r.timestamp) }
    }

    mutating func reset(at date: Date = Date()) {
        maxV = nil
        minV = nil
        maxI = nil
        minI = nil
        maxW = nil
        since = date
    }
}
