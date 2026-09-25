import Foundation

// Compatibility shim for the 1.0 views (LiveView/HistoryView). Frozen; removed in the
// post-merge cleanup once no callers remain. New code uses MetricFormatter directly.
enum Fmt {
    private static let formatter = MetricFormatter(precision: 4)

    static func value(_ v: Double?, _ digits: Int = 3) -> String {
        formatter.number(v, fractionDigits: digits)
    }

    static func duration(_ s: TimeInterval) -> String {
        formatter.duration(s)
    }

    static func energy(_ wh: Double) -> String {
        formatter.energy(wh).text
    }

    static func capacity(_ ah: Double) -> String {
        formatter.capacity(ah).text
    }
}
