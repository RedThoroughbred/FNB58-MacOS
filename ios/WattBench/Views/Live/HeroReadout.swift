import SwiftUI

// MARK: - Pure decisions (unit tested in HeroStateTests)

/// How old the newest sample is, in the three bands the face cares about.
enum Staleness: Equatable {
    /// Samples are flowing.
    case fresh
    /// No sample for more than `HeroState.staleAfter`: numerals dim, the pill
    /// reads "No data".
    case stale
    /// No sample for more than `HeroState.pausedAfter`: the trip card shows
    /// its paused glyph (the gap guard has stopped integrating).
    case paused

    init(latest: Date?, now: Date) {
        if HeroState.isStale(latest: latest, now: now, after: HeroState.pausedAfter) {
            self = .paused
        } else if HeroState.isStale(latest: latest, now: now) {
            self = .stale
        } else {
            self = .fresh
        }
    }
}

/// The logic behind the hero face, kept free of SwiftUI so it can be tested.
enum HeroState {
    /// Numerals dim and the pill reads "No data" once the newest sample is
    /// older than this.
    static let staleAfter: TimeInterval = 2
    /// The trip card shows its paused glyph after this; it matches the gap
    /// guard that stops integration.
    static let pausedAfter: TimeInterval = SessionStats.maxGapS

    /// True when the newest sample (or the lack of one) is older than `after`.
    static func isStale(latest: Date?, now: Date, after: TimeInterval = staleAfter) -> Bool {
        guard let latest else { return true }
        return now.timeIntervalSince(latest) > after
    }

    /// The two metrics shown as secondary tiles, always in V, A, W order.
    static func secondaryOrder(for hero: Metric) -> [Metric] {
        Metric.allCases.filter { $0 != hero }
    }

    /// Whether the instrument face (hero, trip, chart) is shown instead of the
    /// empty state. A dropped connection keeps the face so the last values,
    /// the trip and the chart stay readable while the reconnect is pending.
    static func showsFace(_ state: ConnectionState) -> Bool {
        switch state {
        case .connected, .demo, .reconnecting, .unreachable:
            return true
        case .bluetoothOff, .unauthorized, .idle, .scanning, .connecting:
            return false
        }
    }

    /// Caption under a secondary tile: "PEAK 27.4 W · 14:02:11" for current
    /// and power, the min–max span ("9.01–9.05 V") for voltage. Nil before
    /// the first sample.
    static func peakCaption(_ metric: Metric, extremes: Extremes, formatter: MetricFormatter,
                            locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .current) -> String? {
        switch metric {
        case .voltage:
            guard let lo = extremes.minV, let hi = extremes.maxV else { return nil }
            let low = formatter.format(lo.value, .voltage)
            let high = formatter.format(hi.value, .voltage)
            return "\(low.number)–\(high.number) \(high.unit)"
        case .current:
            guard let peak = extremes.maxI else { return nil }
            return peakText(peak, metric: .current, formatter: formatter, locale: locale, timeZone: timeZone)
        case .power:
            guard let peak = extremes.maxW else { return nil }
            return peakText(peak, metric: .power, formatter: formatter, locale: locale, timeZone: timeZone)
        }
    }

    /// The value copied by "Copy value" on a tile or the hero.
    static func copyText(_ value: Double?, metric: Metric, formatter: MetricFormatter) -> String {
        formatter.format(value, metric).text
    }

    private static func peakText(_ peak: Extremes.Sample, metric: Metric, formatter: MetricFormatter,
                                 locale: Locale, timeZone: TimeZone) -> String {
        let value = formatter.format(peak.value, metric)
        return "PEAK \(value.text) · \(clock(peak.at, locale: locale, timeZone: timeZone))"
    }

    /// 24-hour "hh:mm:ss" in the given locale and zone.
    static func clock(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .current) -> String {
        // `amPM: .omitted` alone keeps a 12-hour locale's hour cycle, so the
        // cycle is forced on the locale itself.
        var components = Locale.Components(locale: locale)
        components.hourCycle = .zeroToTwentyThree
        let style = Date.FormatStyle(locale: Locale(components: components), timeZone: timeZone)
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
            .second(.twoDigits)
        return date.formatted(style)
    }
}

// MARK: - View

/// One large numeral for `Preferences.heroMetric` with the other two metrics
/// as tappable tiles below it. Reads `MeterManager.display` (5 Hz), never
/// `latest`.
struct HeroReadout: View {
    /// From the parent's 1 Hz staleness check; the body re-checks against
    /// the newest sample so fresh data brightens the numerals immediately.
    let isStale: Bool

    @Environment(MeterManager.self) private var meter
    @Environment(Preferences.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Namespace private var promotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 56
    /// Previous unit range per metric so the milli/base decision has hysteresis.
    @State private var ranges: [Metric: UnitRange] = [:]

    var body: some View {
        let frame = meter.display
        let latest = frame.latest
        let hero = prefs.heroMetric
        let formatter = prefs.formatter
        let stale = isStale && HeroState.isStale(latest: latest?.timestamp, now: Date())

        VStack(alignment: .leading, spacing: 12) {
            heroValue(hero, latest: latest, formatter: formatter, stale: stale)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { tiles(hero, latest: latest, extremes: frame.extremes, formatter: formatter, stale: stale) }
                VStack(spacing: 12) { tiles(hero, latest: latest, extremes: frame.extremes, formatter: formatter, stale: stale) }
            }
        }
        .onChange(of: latest?.id) { _, _ in updateRanges(latest) }
        .liveFeedback(.selection, trigger: hero)
    }

    // MARK: Hero numeral

    private func heroValue(_ metric: Metric, latest: Reading?, formatter: MetricFormatter, stale: Bool) -> some View {
        let value = latest.map(metric.value)
        let formatted = format(value, metric, formatter: formatter)
        return VStack(alignment: .leading, spacing: 2) {
            LiveLabel(metric.title)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(formatted.number)
                    .font(.system(size: heroSize, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(stale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(metric.color))
                    .rollingNumber(value ?? 0)
                Text(formatted.unit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .matchedGeometryEffect(id: metric, in: promotion, properties: reduceMotion ? [] : .frame)
            .id(metric)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reset Peaks", systemImage: "arrow.counterclockwise") { meter.resetExtremes() }
            Button("Copy Value", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = HeroState.copyText(value, metric: metric, formatter: formatter)
            }
            Divider()
            Text("Peaks are 100 ms samples")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(stale ? "no recent data" : formatter.spoken(value, metric))
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Secondary tiles

    @ViewBuilder
    private func tiles(_ hero: Metric, latest: Reading?, extremes: Extremes, formatter: MetricFormatter, stale: Bool) -> some View {
        ForEach(HeroState.secondaryOrder(for: hero), id: \.self) { metric in
            let value = latest.map(metric.value)
            SecondaryTile(metric: metric,
                          formatted: format(value, metric, formatter: formatter),
                          spoken: formatter.spoken(value, metric),
                          caption: HeroState.peakCaption(metric, extremes: extremes, formatter: formatter, locale: locale),
                          isStale: stale,
                          value: value ?? 0,
                          onPromote: { promote(metric) },
                          onResetPeaks: { meter.resetExtremes() },
                          onCopy: { UIPasteboard.general.string = HeroState.copyText(value, metric: metric, formatter: formatter) })
            .matchedGeometryEffect(id: metric, in: promotion, properties: reduceMotion ? [] : .frame)
        }
    }

    private func promote(_ metric: Metric) {
        guard metric != prefs.heroMetric else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) {
            prefs.heroMetric = metric
        }
    }

    // MARK: Unit ranges (hysteresis)

    private func format(_ value: Double?, _ metric: Metric, formatter: MetricFormatter) -> FormattedValue {
        guard let value, value.isFinite else { return formatter.format(nil, metric) }
        guard formatter.autoRange else { return formatter.format(value, metric, range: .base) }
        return formatter.format(value, metric, range: UnitRange.range(for: value, metric: metric, previous: ranges[metric]))
    }

    private func updateRanges(_ latest: Reading?) {
        guard let latest, prefs.autoRangeUnits else { return }
        var next = ranges
        for metric in Metric.allCases {
            next[metric] = UnitRange.range(for: metric.value(latest), metric: metric, previous: ranges[metric])
        }
        if next != ranges { ranges = next }
    }
}
