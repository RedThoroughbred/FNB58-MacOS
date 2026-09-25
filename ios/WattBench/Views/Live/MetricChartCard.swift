import Accessibility
import Charts
import SwiftUI

/// What the live chart plots: one metric, or all three on a shared
/// normalised axis.
enum ChartMetric: String, CaseIterable, Identifiable {
    case voltage, current, power, all

    var id: String { rawValue }

    var metric: Metric? {
        switch self {
        case .voltage: return .voltage
        case .current: return .current
        case .power: return .power
        case .all: return nil
        }
    }

    var label: String { metric?.symbol ?? "All" }
    var title: String { metric?.title ?? "All metrics" }

    init(_ metric: Metric) {
        switch metric {
        case .voltage: self = .voltage
        case .current: self = .current
        case .power: self = .power
        }
    }
}

/// The one interactive chart of the Live face. Reads `meter.chart` (the 5 Hz
/// snapshot), the recording's markers and the peak-hold extremes; never
/// `meter.latest`, so the 10 Hz stream cannot invalidate it.
struct MetricChartCard: View {
    @Environment(MeterManager.self) private var meter
    @Environment(Preferences.self) private var prefs
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("chart.metric") private var metricRaw = ChartMetric.power.rawValue
    /// 0 means "not chosen in this scene": `Preferences.defaultWindow` applies.
    @SceneStorage("chart.window") private var windowRaw = 0.0
    @State private var cursor: Date?
    @State private var scrollX = Date.distantPast
    @State private var following = true

    /// Sized so the whole face (hero, tiles, trip, chart) fits above the
    /// record bar on a 6.1-inch phone without scrolling.
    static let plotHeight: CGFloat = 130

    private var selection: ChartMetric {
        get { ChartMetric(rawValue: metricRaw) ?? .power }
        nonmutating set { metricRaw = newValue.rawValue }
    }

    private var window: ChartWindow {
        get { ChartWindow.nearest(to: windowRaw > 0 ? windowRaw : prefs.defaultWindow) }
        nonmutating set { windowRaw = newValue.rawValue }
    }

    var body: some View {
        let snapshot = meter.chart
        let markers = meter.recording?.markers ?? []
        let formatter = prefs.formatter
        let selection = self.selection
        let window = self.window
        let peak = selection.metric.flatMap { peakValue($0, extremes: meter.extremes) }

        VStack(alignment: .leading, spacing: 8) {
            header(selection, last: snapshot.points.last, formatter: formatter)

            LiveChartPlot(points: snapshot.points,
                          gaps: snapshot.gaps,
                          markers: markers,
                          selection: selection,
                          window: window,
                          peak: prefs.showPeakLine ? peak : nil,
                          formatter: formatter,
                          differentiateWithoutColor: differentiateWithoutColor,
                          reduceMotion: reduceMotion,
                          cursor: $cursor,
                          scrollX: $scrollX,
                          following: $following)
                .frame(height: Self.plotHeight)
                .overlay {
                    if snapshot.points.isEmpty, meter.state.isConnected {
                        Text("Waiting for data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !following, !snapshot.points.isEmpty {
                        Button {
                            resumeLive(snapshot.points, window: window)
                        } label: {
                            Label("Live", systemImage: "arrow.right.to.line")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .padding(4)
                    }
                }

            Picker("Window", selection: Binding(get: { window }, set: { self.window = $0 })) {
                ForEach(ChartWindow.allCases) { w in
                    Text(w.label).tag(w).accessibilityLabel(w.spokenLabel)
                }
            }
            .pickerStyle(.segmented)
        }
        .liveCard()
        .onChange(of: snapshot.publishedAt) { _, _ in
            guard following, let last = snapshot.points.last else { return }
            scrollX = ChartWindow.pinnedStart(last: last.timestamp, window: window)
        }
        .onChange(of: window) { _, newWindow in
            guard following, let last = snapshot.points.last else { return }
            scrollX = ChartWindow.pinnedStart(last: last.timestamp, window: newWindow)
        }
        .onChange(of: scrollX) { _, position in
            // The user scrolled back further than one snapshot step: stop pinning.
            guard following, let last = snapshot.points.last else { return }
            let pinned = ChartWindow.pinnedStart(last: last.timestamp, window: window)
            if !ChartWindow.isFollowing(scrollX: position, pinnedStart: pinned) { following = false }
        }
        .liveFeedback(.selection, trigger: metricRaw)
        .liveFeedback(.selection, trigger: windowRaw)
    }

    // MARK: Header

    /// Metric picker (the card's title), the live value of the selected
    /// metric and the options menu on one row.
    private func header(_ selection: ChartMetric, last: Reading?, formatter: MetricFormatter) -> some View {
        HStack(spacing: 8) {
            Picker("Metric", selection: Binding(get: { selection }, set: { self.selection = $0 })) {
                ForEach(ChartMetric.allCases) { m in
                    Text(m.label).tag(m).accessibilityLabel(m.title)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer(minLength: 4)
            if selection != .all {
                Text(liveValue(selection, last: last, formatter: formatter))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel("Latest \(selection.title.lowercased())")
            }
            Menu {
                Toggle("Show Peak Line", systemImage: "chart.line.flattrend.xyaxis", isOn: Binding(
                    get: { prefs.showPeakLine }, set: { prefs.showPeakLine = $0 }))
                Button("Copy Value Under Cursor", systemImage: "doc.on.doc") { copyCursorValue(formatter) }
                    .disabled(cursor == nil)
                Divider()
                Button("Clear Chart", systemImage: "eraser", role: .destructive) {
                    meter.clearHistory()
                    following = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Chart options")
        }
    }

    private func liveValue(_ selection: ChartMetric, last: Reading?, formatter: MetricFormatter) -> String {
        guard let last else { return "" }
        if let metric = selection.metric {
            return formatter.format(metric.value(last), metric).text
        }
        return Metric.allCases.map { formatter.format($0.value(last), $0).text }.joined(separator: " · ")
    }

    private func peakValue(_ metric: Metric, extremes: Extremes) -> Double? {
        switch metric {
        case .voltage: return extremes.maxV?.value
        case .current: return extremes.maxI?.value
        case .power: return extremes.maxW?.value
        }
    }

    private func copyCursorValue(_ formatter: MetricFormatter) {
        let points = meter.chart.points
        guard let cursor, let i = ChartWindow.nearestIndex(in: points, to: cursor) else { return }
        let p = points[i]
        let values: String
        if let metric = selection.metric {
            values = formatter.format(metric.value(p), metric).text
        } else {
            values = Metric.allCases.map { formatter.format($0.value(p), $0).text }.joined(separator: " · ")
        }
        UIPasteboard.general.string = "\(values) at \(HeroState.clock(p.timestamp))"
    }

    private func resumeLive(_ points: [Reading], window: ChartWindow) {
        guard let last = points.last else { return }
        following = true
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            scrollX = ChartWindow.pinnedStart(last: last.timestamp, window: window)
        }
    }
}

// MARK: - Plot

/// The plot itself, taking only values so a body evaluation happens exactly
/// when a new snapshot, marker, selection or window arrives.
struct LiveChartPlot: View {
    let points: [Reading]
    let gaps: [DateInterval]
    let markers: [Marker]
    let selection: ChartMetric
    let window: ChartWindow
    /// Peak-hold value of the selected metric (nil hides the line).
    let peak: Double?
    let formatter: MetricFormatter
    let differentiateWithoutColor: Bool
    let reduceMotion: Bool
    @Binding var cursor: Date?
    @Binding var scrollX: Date
    @Binding var following: Bool

    private static let seriesTitles = Metric.allCases.map(\.title)

    var body: some View {
        let visible = visibleSlice
        let scales = Self.scales(for: visible)
        let domain = yDomain(visible)

        chart(scales: scales, domain: domain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .chartYAxis {
                if selection == .all {
                    AxisMarks(position: .leading, values: [0, 0.5, 1]) { _ in AxisGridLine() }
                } else {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: xDomain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: window.seconds)
            .chartScrollPosition(x: $scrollX)
            .chartXSelection(value: $cursor)
            .chartLegend(selection == .all ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .leading, spacing: 4)
            .chartForegroundStyleScale(domain: Self.seriesTitles, range: Metric.allCases.map(\.color))
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: domain)
            .accessibilityChartDescriptor(self)
    }

    // MARK: Marks

    private func chart(scales: [Metric: ChartWindow.Scale], domain: ClosedRange<Double>) -> some View {
        Chart {
            if let metric = selection.metric {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.timestamp), y: .value(metric.title, metric.value(p)))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(metric.color)
                    AreaMark(x: .value("Time", p.timestamp), y: .value(metric.title, metric.value(p)))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [metric.color.opacity(0.25), metric.color.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                }
            } else {
                ForEach(Metric.allCases) { metric in
                    let scale = scales[metric]
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.timestamp),
                                 y: .value("Normalised", scale?.normalise(metric.value(p)) ?? 0.5),
                                 series: .value("Metric", metric.title))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: differentiateWithoutColor ? Self.dash(for: metric) : []))
                            .foregroundStyle(by: .value("Metric", metric.title))
                    }
                }
            }

            ForEach(gaps, id: \.start) { gap in
                RectangleMark(xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end))
                    .foregroundStyle(Color.secondary.opacity(0.15))
            }

            ForEach(markers) { marker in
                RuleMark(x: .value("Marker", marker.timestamp))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.accentColor)
                    // Inside the plot: anything above the plot area is
                    // clipped by the scrollable chart.
                    .annotation(position: .overlay, alignment: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        Text(marker.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: Capsule())
                            // An overlay annotation is proposed the rule's 1 pt width.
                            .fixedSize()
                    }
            }

            if let peak, let metric = selection.metric {
                RuleMark(y: .value("Peak", peak))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(metric.color.opacity(0.6))
                    .annotation(position: .bottom, alignment: .trailing, spacing: 1) {
                        Text("peak")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            if let cursor, let i = ChartWindow.nearestIndex(in: points, to: cursor) {
                let p = points[i]
                RuleMark(x: .value("Cursor", p.timestamp))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .overlay, alignment: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        readout(p)
                    }
                if let metric = selection.metric {
                    PointMark(x: .value("Cursor", p.timestamp), y: .value(metric.title, metric.value(p)))
                        .symbolSize(48)
                        .foregroundStyle(metric.color)
                }
            }
        }
    }

    private func readout(_ p: Reading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let metric = selection.metric {
                Text(formatter.format(metric.value(p), metric).text)
                    .font(.callout.monospacedDigit().weight(.semibold))
            } else {
                ForEach(Metric.allCases) { metric in
                    Text(formatter.format(metric.value(p), metric).text)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(metric.color)
                }
            }
            Text(p.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }

    // MARK: Scales

    /// Scrollable extent: at least one window wide so the newest sample can
    /// be pinned to the trailing edge from the first sample on.
    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else {
            let now = Date()
            return ChartWindow.pinnedStart(last: now, window: window)...now
        }
        return ChartWindow.xDomain(first: first, last: last, window: window)
    }

    /// The readings inside the visible window: the trailing window while
    /// following, otherwise the window at the scroll position.
    private var visibleSlice: ArraySlice<Reading> {
        if following { return ChartWindow.trailing(points, window: window) }
        return ChartWindow.slice(points, from: scrollX, to: scrollX.addingTimeInterval(window.seconds))
    }

    private static func scales(for visible: ArraySlice<Reading>) -> [Metric: ChartWindow.Scale] {
        var out: [Metric: ChartWindow.Scale] = [:]
        for metric in Metric.allCases {
            out[metric] = ChartWindow.Scale(visible.lazy.map(metric.value))
        }
        return out
    }

    private func yDomain(_ visible: ArraySlice<Reading>) -> ClosedRange<Double> {
        guard let metric = selection.metric else { return -0.05...1.05 }
        let raw = ChartWindow.yDomain(visible.map(metric.value), including: peak)
        return ChartWindow.stabilised(raw)
    }

    private static func dash(for metric: Metric) -> [CGFloat] {
        switch metric {
        case .voltage: return []
        case .current: return [6, 3]
        case .power: return [2, 3]
        }
    }
}

// MARK: - Audio graph

extension LiveChartPlot: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let start = points.first?.timestamp ?? Date()
        let elapsed = points.map { $0.timestamp.timeIntervalSince(start) }
        let xAxis = AXNumericDataAxisDescriptor(title: "Time", range: 0...(elapsed.last ?? 1),
                                                gridlinePositions: []) { "\(Int($0.rounded())) seconds" }
        let metrics = selection.metric.map { [$0] } ?? Metric.allCases
        let scales = selection == .all ? Self.scales(for: points[...]) : [:]
        let series = metrics.map { metric -> AXDataSeriesDescriptor in
            let values = points.enumerated().map { i, p -> AXDataPoint in
                let v = metric.value(p)
                return AXDataPoint(x: elapsed[i], y: scales[metric]?.normalise(v) ?? v)
            }
            return AXDataSeriesDescriptor(name: metric.title, isContinuous: true, dataPoints: values)
        }
        let yAxis: AXNumericDataAxisDescriptor
        if let metric = selection.metric {
            let domain = ChartWindow.yDomain(points.map(metric.value), including: peak)
            yAxis = AXNumericDataAxisDescriptor(title: metric.title, range: domain, gridlinePositions: []) {
                formatter.format($0, metric).text
            }
        } else {
            yAxis = AXNumericDataAxisDescriptor(title: "Normalised", range: 0...1, gridlinePositions: []) {
                "\(Int(($0 * 100).rounded())) percent of range"
            }
        }
        return AXChartDescriptor(title: "Live \(selection.title.lowercased())", summary: nil,
                                 xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series)
    }
}
