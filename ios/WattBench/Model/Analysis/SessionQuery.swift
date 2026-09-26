import Foundation

/// Orderings offered by the Sessions list's Sort menu (persisted by raw value).
enum SortOrder: String, CaseIterable, Identifiable {
    case newest, longest, mostEnergy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest"
        case .longest: return "Longest"
        case .mostEnergy: return "Most energy"
        }
    }

    var symbolName: String {
        switch self {
        case .newest: return "clock"
        case .longest: return "timer"
        case .mostEnergy: return "bolt"
        }
    }
}

/// Pure grouping, searching and sorting over session summaries.
struct SessionQuery {
    /// Groups by calendar day (newest day first), keeping the input order
    /// inside each day. Days are `calendar.startOfDay` values, so sessions on
    /// either side of midnight and of a DST change land in the right day.
    static func group(_ summaries: [SessionSummary], calendar: Calendar) -> [(day: Date, sessions: [SessionSummary])] {
        var order: [Date] = []
        var buckets: [Date: [SessionSummary]] = [:]
        for s in summaries {
            let day = calendar.startOfDay(for: s.startTime)
            if buckets[day] == nil {
                order.append(day)
                buckets[day] = []
            }
            buckets[day]?.append(s)
        }
        return order.sorted(by: >).map { (day: $0, sessions: buckets[$0] ?? []) }
    }

    /// Case- and diacritic-insensitive match over name, device name, tags and
    /// notes. Every whitespace-separated term must match somewhere; a leading
    /// `#` on a term is ignored so tag completions read naturally. Blank
    /// queries return everything.
    static func filter(_ summaries: [SessionSummary], query: String) -> [SessionSummary] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { term -> String in
                let t = String(term)
                return t.hasPrefix("#") ? String(t.dropFirst()) : t
            }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return summaries }
        return summaries.filter { s in terms.allSatisfy { matches(s, term: $0) } }
    }

    /// Deterministic orderings: ties fall back to the newest start, then the
    /// identifier, so the list never reshuffles between evaluations.
    static func sorted(_ summaries: [SessionSummary], by order: SortOrder) -> [SessionSummary] {
        summaries.sorted { a, b in
            switch order {
            case .newest:
                break
            case .longest:
                if a.stats.durationS != b.stats.durationS { return a.stats.durationS > b.stats.durationS }
            case .mostEnergy:
                if a.stats.energyWh != b.stats.energyWh { return a.stats.energyWh > b.stats.energyWh }
            }
            if a.startTime != b.startTime { return a.startTime > b.startTime }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Distinct tags in order of most recent use (for search suggestions).
    static func recentTags(_ summaries: [SessionSummary], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in summaries.sorted(by: { $0.startTime > $1.startTime }) {
            for tag in s.tags where !tag.isEmpty {
                let key = tag.lowercased()
                if seen.insert(key).inserted {
                    out.append(tag)
                    if out.count == limit { return out }
                }
            }
        }
        return out
    }

    /// "Today" / "Yesterday" for the two most recent days, nil otherwise (the
    /// caller then formats the date).
    static func relativeDayName(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return nil
    }

    // MARK: Internals

    private static func matches(_ s: SessionSummary, term: String) -> Bool {
        func hit(_ text: String?) -> Bool {
            text?.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return hit(s.name) || hit(s.deviceName) || hit(s.notes) || s.tags.contains(where: { hit($0) })
    }
}
