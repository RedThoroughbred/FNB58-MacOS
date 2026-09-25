import Charts
import SwiftUI

/// Visible-window presets for the detail chart. `all` stands for the whole
/// session; pinching produces windows in between the presets.
enum SessionChartSpan: Double, CaseIterable, Identifiable {
    case all = 0
    case hour = 3600
    case tenMinutes = 600
    case minute = 60

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .hour: return "1 h"
        case .tenMinutes: return "10 min"
        case .minute: return "1 min"
        }
    }
}

/// State behind `SessionChart`: the loaded samples, the visible window and
/// scroll position, the scrub cursor and range selection, and the decimated
/// points handed to Swift Charts.
///
/// The raw array never reaches a `Chart`. Points are min/max buckets of the
/// slice around the visible window (three window-widths, page aligned so
/// scrolling inside a page reuses them), recomputed off the main actor after
/// a 100 ms debounce and cached per (metric, slice, bucket count). Cursor
/// lookups are binary searches.
@MainActor
@Observable
final class SessionChartModel {
    static let minVisibleSeconds: TimeInterval = 10
    /// Upper bound on marks handed to the chart per series.
    static let maxMarks = 1500
    static let debounce: Duration = .milliseconds(100)
    private static let cacheLimit = 16

    struct Computed: Equatable {
        var points: [DecimatedPoint]
        var hasEnvelope: Bool
        var yDomain: ClosedRange<Double>
    }

    private struct CacheKey: Hashable {
        let metric: Metric
        let slice: Range<Int>
        let targetCount: Int
    }

    // MARK: Inputs

    private(set) var readings: [Reading] = []
    var markers: [Marker] = []
    /// Wall-clock span drawn on the x axis (the session span, widened to the
    /// samples when they fall outside it).
    private(set) var start: Date
    private(set) var end: Date

    // MARK: View state

    var metric: Metric = .power {
        didSet { if metric != oldValue { scheduleRecompute() } }
    }
    private(set) var visibleSeconds: TimeInterval
    /// Leading edge of the visible window.
    var scrollPosition: Date {
        didSet { if scrollPosition != oldValue { scheduleRecompute() } }
    }
    var cursor: Date?
    var range: ClosedRange<Date>?
    /// Width of the plot area in points; drives the bucket count.
    var plotWidth: Double = 320 {
        didSet { if plotWidth != oldValue { scheduleRecompute() } }
    }
    var displayScale: Double = 3

    // MARK: Outputs

    private(set) var points: [DecimatedPoint] = []
    private(set) var hasEnvelope = false
    private(set) var yDomain: ClosedRange<Double> = 0...1
    private(set) var gaps: [DateInterval] = []

    @ObservationIgnored private var cache: [CacheKey: Computed] = [:]
    @ObservationIgnored private var cacheOrder: [CacheKey] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var magnifyBase: TimeInterval?

    init(start: Date, end: Date, markers: [Marker] = []) {
        self.start = start
        self.end = max(end, start)
        self.markers = markers
        self.visibleSeconds = max(end.timeIntervalSince(start), 0)
        self.scrollPosition = start
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isEmpty: Bool { readings.isEmpty }

    /// The preset matching the current window, nil for a pinched window.
    var currentSpan: SessionChartSpan? {
        if abs(visibleSeconds - duration) < 0.5 { return .all }
        return SessionChartSpan.allCases.first { $0 != .all && abs($0.rawValue - visibleSeconds) < 0.5 }
    }

    /// Presets that fit inside the session (plus `all`).
    var availableSpans: [SessionChartSpan] {
        SessionChartSpan.allCases.filter { $0 == .all || $0.rawValue < duration }
    }

    // MARK: Inputs

    /// Installs the loaded samples, widening the axis to cover them, and
    /// resets the window to the whole session.
    func setReadings(_ r: [Reading]) {
        readings = r
        if let first = r.first?.timestamp, first < start { start = first }
        if let last = r.last?.timestamp, last > end { end = last }
        gaps = Decimator.gaps(in: r[...])
        cache.removeAll()
        cacheOrder.removeAll()
        visibleSeconds = duration
        scrollPosition = start
        cursor = nil
        range = nil
        scheduleRecompute(immediate: true)
    }

    // MARK: Window

    func select(span: SessionChartSpan) {
        setVisible(span == .all ? duration : span.rawValue, keepingCenter: true)
    }

    /// Sets the window length, clamped to 10 s ... the session, optionally
    /// keeping the window's centre in place.
    func setVisible(_ seconds: TimeInterval, keepingCenter: Bool) {
        let lower = min(Self.minVisibleSeconds, duration)
        let clamped = min(max(seconds, lower), max(duration, lower))
        guard clamped.isFinite else { return }
        let center = scrollPosition.addingTimeInterval(visibleSeconds / 2)
        visibleSeconds = clamped
        if keepingCenter {
            scrollPosition = clampedScroll(center.addingTimeInterval(-clamped / 2))
        } else {
            scrollPosition = clampedScroll(scrollPosition)
        }
        scheduleRecompute()
    }

    /// True between `beginMagnify` and `endMagnify`.
    var isMagnifying: Bool { magnifyBase != nil }

    func beginMagnify() { magnifyBase = visibleSeconds }

    func magnify(by factor: Double) {
        guard let base = magnifyBase, factor.isFinite, factor > 0 else { return }
        setVisible(base / factor, keepingCenter: true)
    }

    func endMagnify() { magnifyBase = nil }

    /// Scrolls so `date` sits in the middle of the window and puts the
    /// cursor there (marker taps).
    func reveal(_ date: Date) {
        scrollPosition = clampedScroll(date.addingTimeInterval(-visibleSeconds / 2))
        cursor = date
    }

    private func clampedScroll(_ date: Date) -> Date {
        let latest = end.addingTimeInterval(-visibleSeconds)
        return min(max(date, start), max(start, latest))
    }

    // MARK: Lookups

    func elapsed(_ date: Date) -> TimeInterval { date.timeIntervalSince(start) }

    /// The raw reading closest to `date` (binary search).
    func nearestReading(to date: Date) -> Reading? {
        RangeStats.nearestIndex(in: readings, to: date).map { readings[$0] }
    }

    /// Indices of the readings inside the selected range.
    func indexRange(for selection: ClosedRange<Date>) -> Range<Int> {
        RangeStats.indexRange(in: readings, from: selection.lowerBound, to: selection.upperBound)
    }

    // MARK: Decimation

    func scheduleRecompute(immediate: Bool = false) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            self?.recompute()
        }
    }

    private func currentKey() -> CacheKey? {
        guard !readings.isEmpty else { return nil }
        let perWindow = Decimator.targetCount(forPixelWidth: plotWidth * displayScale, cap: Self.maxMarks)
        let slice: Range<Int>
        let windows: Int
        if readings.count <= Self.maxMarks || duration <= visibleSeconds * 3 {
            slice = readings.startIndex..<readings.endIndex
            windows = max(1, min(3, Int((duration / max(visibleSeconds, 1)).rounded(.up))))
        } else {
            // Half-window pages: the slice always covers at least one window
            // behind the leading edge and half a window past the trailing one.
            let half = visibleSeconds / 2
            let page = max(0, floor(scrollPosition.timeIntervalSince(start) / half))
            let sliceStart = start.addingTimeInterval(max(0, page - 2) * half)
            let sliceEnd = min(end, sliceStart.addingTimeInterval(3 * visibleSeconds))
            slice = RangeStats.indexRange(in: readings, from: sliceStart, to: sliceEnd)
            windows = 3
        }
        return CacheKey(metric: metric, slice: slice, targetCount: min(Self.maxMarks, perWindow * windows))
    }

    private func recompute() {
        guard let key = currentKey() else {
            points = []
            hasEnvelope = false
            yDomain = 0...1
            return
        }
        if let cached = cache[key] {
            apply(cached)
            return
        }
        generation += 1
        let gen = generation
        let readings = self.readings
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { () -> Computed in
                let pts = Decimator.minMaxBuckets(readings[key.slice], metric: key.metric, targetCount: key.targetCount)
                return Computed(points: pts,
                                hasEnvelope: key.slice.count > key.targetCount,
                                yDomain: Decimator.yDomain(pts))
            }.value
            guard let self, self.generation == gen else { return }
            self.store(computed, for: key)
            self.apply(computed)
        }
    }

    private func store(_ computed: Computed, for key: CacheKey) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = computed
        while cacheOrder.count > Self.cacheLimit {
            let old = cacheOrder.removeFirst()
            cache[old] = nil
        }
    }

    private func apply(_ computed: Computed) {
        if computed.points != points { points = computed.points }
        hasEnvelope = computed.hasEnvelope
        yDomain = computed.yDomain
    }
}

/// The per-metric session chart: min/max envelope under the mean line,
/// gap bands, dashed marker rules, a scrollable window with presets and
/// pinch zoom, a long-press scrub cursor and a long-press-drag range
/// selection.
struct SessionChart: View {
    @Bindable var model: SessionChartModel
    /// Sparkline from the summary, drawn as a placeholder until samples load.
    var placeholder: [Float] = []
    var isLoading = false

    @Environment(Preferences.self) private var prefs
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let plotHeight: CGFloat = 260
    static let readoutHeadroom: CGFloat = 40

    private var sortedMarkers: [Marker] { model.markers.sorted { $0.timestamp < $1.timestamp } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Metric", selection: $model.metric) {
                ForEach(Metric.allCases) { m in
                    Text(m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Chart metric")

            Group {
                if model.isEmpty {
                    placeholderChart
                } else {
                    chart
                }
            }
            // The plot is `plotHeight` tall; the headroom above it holds the
            // scrub readout so it never covers the trace.
            .frame(height: Self.plotHeight + Self.readoutHeadroom)

            if model.availableSpans.count > 1 || model.currentSpan == nil {
                spanPicker
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .sensoryFeedback(.selection, trigger: model.metric) { _, _ in !reduceMotion && prefs.hapticsEnabled }
        .onChange(of: displayScale, initial: true) { _, scale in model.displayScale = scale }
    }

    // MARK: Chart

    private var color: Color { model.metric.color }

    private var chart: some View {
        let f = prefs.formatter
        return Chart {
            if model.hasEnvelope {
                ForEach(model.points.indices, id: \.self) { i in
                    let p = model.points[i]
                    AreaMark(x: .value("Time", p.time),
                             yStart: .value("Min", p.min),
                             yEnd: .value("Max", p.max))
                        .foregroundStyle(color.opacity(0.18))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(model.points.indices, id: \.self) { i in
                let p = model.points[i]
                LineMark(x: .value("Time", p.time), y: .value(model.metric.title, p.mean))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(model.gaps.indices, id: \.self) { i in
                let g = model.gaps[i]
                RectangleMark(xStart: .value("Gap start", g.start), xEnd: .value("Gap end", g.end))
                    .foregroundStyle(.secondary.opacity(0.15))
            }
            // Labels sit inside the plot at the top, cycling through three
            // rows so neighbouring markers do not cover each other.
            ForEach(Array(sortedMarkers.enumerated()), id: \.element.id) { index, m in
                let tint = Self.tint(for: m)
                RuleMark(x: .value("Marker", m.timestamp))
                    .foregroundStyle(tint.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .plot), y: .disabled)) {
                        Text(m.label)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(tint)
                            .background(tint.opacity(0.14), in: Capsule())
                            .padding(.leading, 3)
                            .padding(.top, 4 + CGFloat(index % 3) * 19)
                            // The annotation frame is as wide as the rule;
                            // keep the label at its natural size.
                            .fixedSize()
                    }
            }
            if let range = model.range {
                RectangleMark(xStart: .value("Range start", range.lowerBound),
                              xEnd: .value("Range end", range.upperBound))
                    .foregroundStyle(color.opacity(0.12))
                RuleMark(x: .value("Range start", range.lowerBound)).foregroundStyle(color.opacity(0.7))
                RuleMark(x: .value("Range end", range.upperBound)).foregroundStyle(color.opacity(0.7))
            }
            if let cursor = model.cursor, let r = model.nearestReading(to: cursor) {
                RuleMark(x: .value("Cursor", r.timestamp))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        cursorReadout(r, formatter: f)
                            .fixedSize()
                    }
            }
        }
        .chartXScale(domain: model.start...model.end)
        .chartYScale(domain: model.yDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: max(model.visibleSeconds, 1))
        .chartScrollPosition(x: $model.scrollPosition)
        .chartXSelection(value: $model.cursor)
        .chartXSelection(range: $model.range)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat, collisionResolution: .greedy)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartPlotStyle { plot in
            plot.background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { model.plotWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in model.plotWidth = w }
                }
            )
        }
        // Headroom for the scrub readout, which floats above the plot.
        .padding(.top, Self.readoutHeadroom)
        .simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.02)
                .onChanged { value in
                    if !model.isMagnifying { model.beginMagnify() }
                    model.magnify(by: value.magnification)
                }
                .onEnded { _ in model.endMagnify() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.metric.title) chart")
        .accessibilityValue(accessibilitySummary(formatter: f))
    }

    private var axisFormat: Date.FormatStyle {
        model.visibleSeconds < 900 ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
    }

    private func cursorReadout(_ r: Reading, formatter f: MetricFormatter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(f.duration(model.elapsed(r.timestamp)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Metric.allCases) { m in
                    Text(f.format(m.value(r), m).text)
                        .font(.caption.monospacedDigit().weight(m == model.metric ? .semibold : .regular))
                        .foregroundStyle(m == model.metric ? m.color : Color.primary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func accessibilitySummary(formatter f: MetricFormatter) -> String {
        guard let lo = model.points.map(\.min).min(), let hi = model.points.map(\.max).max() else {
            return "No samples"
        }
        return "from \(f.spoken(lo, model.metric)) to \(f.spoken(hi, model.metric))"
    }

    static func tint(for marker: Marker) -> Color {
        switch marker.kind {
        case .alert, .autoStop: return .red
        case .gap: return .secondary
        case .user: return .accentColor
        }
    }

    // MARK: Placeholder

    /// The summary sparkline stretched over the session span; redacted while
    /// samples load, plain when there are none.
    private var placeholderChart: some View {
        let n = placeholder.count
        let step = n > 1 ? model.duration / Double(n - 1) : 0
        return Chart {
            ForEach(placeholder.indices, id: \.self) { i in
                LineMark(x: .value("Time", model.start.addingTimeInterval(Double(i) * step)),
                         y: .value("Power", Double(placeholder[i])))
                    .foregroundStyle(Color.power.opacity(0.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .padding(.top, Self.readoutHeadroom)
        .redacted(reason: isLoading ? .placeholder : [])
        .overlay {
            if isLoading {
                ProgressView()
            } else if placeholder.isEmpty {
                Text("No samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Window picker

    private var spanPicker: some View {
        Picker("Window", selection: spanSelection) {
            ForEach(model.availableSpans) { span in
                Text(span.label).tag(Optional(span))
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Chart window")
    }

    private var spanSelection: Binding<SessionChartSpan?> {
        Binding(get: { model.currentSpan },
                set: { if let span = $0 { model.select(span: span) } })
    }
}
