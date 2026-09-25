import SwiftUI

/// A saved session as a report: stat tiles from the summary, a per-metric
/// scroll/zoom chart with min/max envelope, scrub cursor and range
/// selection, markers, notes, tags and an integrity section. Samples are
/// loaded lazily; everything derived from the summary renders at once.
struct SessionDetailView: View {
    let id: UUID

    @Environment(SessionStore.self) private var store
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum LoadState: Equatable {
        case loading, loaded, failed(String)
    }

    @State private var chart: SessionChartModel?
    /// The fully loaded session (samples included); nil until loaded and
    /// nil when the samples could not be read.
    @State private var session: Session?
    @State private var loadState: LoadState = .loading
    @State private var title = ""
    @State private var notes = ""
    @FocusState private var notesFocused: Bool
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var showTagEditor = false
    @State private var rangeStats: SessionStats?
    @State private var errorMessage: String?
    /// Bumped on marker changes and deletion for the light impact haptic.
    @State private var editCount = 0

    private var summary: SessionSummary? { store.summaries.first { $0.id == id } }
    private var feedbackEnabled: Bool { !reduceMotion && prefs.hapticsEnabled }

    var body: some View {
        Group {
            if let summary {
                report(summary)
            } else {
                ContentUnavailableView("Session Not Found", systemImage: "questionmark.folder",
                                       description: Text("This session is no longer on this phone."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
    }

    // MARK: - Report

    private func report(_ s: SessionSummary) -> some View {
        List {
            headerSection(s)
            highlightsSection(s)
            chartSection(s)
            MarkersSection(markers: chart?.markers ?? s.markers,
                           readings: chart?.readings ?? [],
                           sessionStart: chart?.start ?? s.startTime,
                           canDelete: session != nil,
                           onSelect: { chart?.reveal($0.timestamp) },
                           onDelete: deleteMarker)
            notesSection
            integritySection(s)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle($title)
        .toolbarTitleMenu { titleMenu(s) }
        .toolbar { toolbar(s) }
        .safeAreaInset(edge: .bottom) { rangeCard(s) }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                SessionErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
        }
        .onChange(of: s.name, initial: true) { _, name in
            if title != name { title = name }
        }
        .onChange(of: s.notes, initial: true) { _, stored in
            if !notesFocused { notes = stored ?? "" }
        }
        .onChange(of: notesFocused) { _, focused in
            if !focused { saveNotes() }
        }
        .onDisappear { saveNotes() }
        .task(id: title) { await persistTitle() }
        .task(id: chart?.range) { await computeRangeStats() }
        .alert("Rename Session", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this session?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) { deleteSession() }
        } message: {
            Text("This removes the recording and its samples. This cannot be undone.")
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorSheet(tags: s.tags, suggestions: SessionQuery.recentTags(store.summaries, limit: 20)) { saveTags($0) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: editCount) { _, _ in feedbackEnabled }
        .saveFeedback(store)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: rangeStats != nil)
    }

    // MARK: Header

    private func headerSection(_ s: SessionSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                tagsRow(s)
                tiles(s)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private func tagsRow(_ s: SessionSummary) -> some View {
        HStack(spacing: 8) {
            if s.tags.isEmpty {
                Button { showTagEditor = true } label: {
                    Label("Add Tags", systemImage: "tag")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            } else {
                SessionTagCapsules(tags: s.tags)
                Spacer(minLength: 8)
                Button("Edit") { showTagEditor = true }
                    .font(.caption.weight(.medium))
                    .accessibilityLabel("Edit tags")
            }
            if s.isDemo { SessionDemoBadge() }
            if s.state == .recovered { SessionRecoveredBadge() }
        }
    }

    private func tiles(_ s: SessionSummary) -> some View {
        let f = prefs.formatter
        let energy = f.energy(s.stats.energyWh)
        let capacity = f.capacity(s.stats.capacityAh, unit: prefs.capacityUnit)
        let energyTile = StatTile(label: "Energy", value: energy.number, unit: energy.unit)
        let capacityTile = StatTile(label: "Capacity", value: capacity.number, unit: capacity.unit,
                                    caption: s.stats.capacityAh < 0 ? "reverse flow" : nil)
        let durationTile = StatTile(label: "Duration", value: f.duration(s.stats.durationS), unit: "active",
                                    caption: "\(f.duration(s.duration)) wall")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                energyTile
                capacityTile
                durationTile
            }
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    energyTile
                    capacityTile
                }
                durationTile
            }
        }
    }

    // MARK: Highlights

    private func highlightsSection(_ s: SessionSummary) -> some View {
        let f = prefs.formatter
        let stats = s.stats
        return Section("Highlights") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 12) {
                SessionStatItem(label: "Avg power", value: f.format(stats.avgPower, .power).text, caption: "time-weighted")
                SessionStatItem(label: "Peak power", value: f.format(stats.maxPower, .power).text)
                SessionStatItem(label: "Voltage", value: f.span(stats.minVoltage, stats.maxVoltage, .voltage))
                SessionStatItem(label: "Current", value: f.span(stats.minCurrent, stats.maxCurrent, .current))
                if stats.gapCount > 0 {
                    SessionStatItem(label: "Gaps", value: "\(stats.gapCount)",
                                    caption: "\(f.duration(stats.gapSeconds)) not integrated")
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Chart

    private func chartSection(_ s: SessionSummary) -> some View {
        Section("Chart") {
            Group {
                if let chart {
                    SessionChart(model: chart, placeholder: s.sparkline, isLoading: loadState == .loading)
                } else {
                    SessionChart(model: SessionChartModel(start: s.startTime, end: s.endTime, markers: s.markers),
                                 placeholder: s.sparkline, isLoading: true)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if case .failed(let message) = loadState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section("Notes") {
            TextField("Add a note", text: $notes, axis: .vertical)
                .lineLimit(2...8)
                .focused($notesFocused)
                .onSubmit(saveNotes)
        }
    }

    // MARK: Integrity

    private func integritySection(_ s: SessionSummary) -> some View {
        let f = prefs.formatter
        return Section("Integrity") {
            row("Samples", "\(s.sampleCount.formatted(.number.locale(f.locale))) · \(f.rate(samples: s.sampleCount, seconds: s.stats.durationS)) Hz")
            if s.stats.gapCount > 0 {
                row("Gaps", "\(s.stats.gapCount) · \(f.duration(s.stats.gapSeconds))")
            }
            row("Recorded", "\(s.startTime.formatted(date: .abbreviated, time: .shortened)) – \(s.endTime.formatted(date: .omitted, time: .shortened))")
            if let device = s.deviceName, !device.isEmpty {
                row("Meter", device)
            }
            if let reason = s.autoStopReason {
                row("Auto-stop", AutoStopRule.Reason(rawValue: reason)?.label ?? reason)
            }
            if s.state == .recovered {
                HStack {
                    Text("State")
                    Spacer()
                    SessionRecoveredBadge()
                    Text("Recovered").foregroundStyle(.secondary)
                }
            }
            if s.isDemo {
                HStack {
                    Text("Source")
                    Spacer()
                    SessionDemoBadge()
                }
            }
            if case .failed = loadState {
                Label("Samples unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Range card

    @ViewBuilder private func rangeCard(_ s: SessionSummary) -> some View {
        if let chart, let range = chart.range, let rangeStats {
            RangeStatsCard(range: range, stats: rangeStats, sessionStart: chart.start,
                           sessionEnergyWh: s.stats.energyWh, canSaveMarkers: session != nil,
                           onSaveMarkers: saveRangeMarkers,
                           onClose: { chart.range = nil })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ s: SessionSummary) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ShareLink(item: export(s), preview: preview(s)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Menu {
                Button { beginRename(s) } label: { Label("Rename", systemImage: "pencil") }
                Button { showTagEditor = true } label: { Label("Edit Tags", systemImage: "tag") }
                Button { copySummary(s) } label: { Label("Copy Summary", systemImage: "doc.on.doc") }
                Divider()
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { notesFocused = false }
        }
    }

    @ViewBuilder private func titleMenu(_ s: SessionSummary) -> some View {
        Button { beginRename(s) } label: { Label("Rename", systemImage: "pencil") }
        ShareLink(item: export(s), preview: preview(s)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button { copySummary(s) } label: { Label("Copy Summary", systemImage: "doc.on.doc") }
        Button(role: .destructive) { showDeleteConfirm = true } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let summary else { return }
        let model = SessionChartModel(start: summary.startTime, end: summary.endTime, markers: summary.markers)
        chart = model
        session = nil
        loadState = .loading
        do {
            var loaded = try await store.session(for: id)
            if loaded.readings.isEmpty, loaded.sampleCount > 0 {
                loaded.readings = try await store.samples(for: id)
            }
            session = loaded
            model.markers = loaded.markers
            model.setReadings(loaded.readings)
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func computeRangeStats() async {
        guard let chart, let range = chart.range, !chart.isEmpty else {
            rangeStats = nil
            return
        }
        let readings = chart.readings
        let indices = chart.indexRange(for: range)
        let stats = await Task.detached(priority: .userInitiated) { RangeStats.stats(readings[indices]) }.value
        guard !Task.isCancelled else { return }
        rangeStats = stats
    }

    // MARK: - Editing

    /// The navigation title is editable in place; commits are debounced so
    /// the file is not rewritten per keystroke.
    private func persistTitle() async {
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, let summary else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != summary.name else { return }
        do {
            try store.rename(id: id, to: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginRename(_ s: SessionSummary) {
        renameText = s.name
        showRename = true
    }

    private func rename() {
        do {
            try store.rename(id: id, to: renameText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveNotes() {
        guard let summary else { return }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (summary.notes ?? "") else { return }
        do {
            try store.update(id: id, notes: trimmed, tags: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveTags(_ tags: [String]) {
        do {
            try store.update(id: id, notes: nil, tags: tags)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteMarker(_ marker: Marker) {
        guard var s = session else { return }
        s.markers.removeAll { $0.id == marker.id }
        persist(s)
    }

    private func saveRangeMarkers() {
        guard var s = session, let range = chart?.range else { return }
        s.markers.append(Marker(timestamp: range.lowerBound, label: "Range start"))
        s.markers.append(Marker(timestamp: range.upperBound, label: "Range end"))
        persist(s)
        chart?.range = nil
    }

    /// Markers live in the session file, so they are saved through
    /// `store.save` with the samples that were loaded (never for a live
    /// recording, which goes through `MeterManager`).
    private func persist(_ s: Session) {
        do {
            try store.save(s)
            session = s
            chart?.markers = s.markers
            editCount += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSession() {
        store.delete(id: id)
        editCount += 1
        dismiss()
    }

    private func copySummary(_ s: SessionSummary) {
        UIPasteboard.general.string = export(s).summaryText
    }

    private func export(_ s: SessionSummary) -> SessionExport {
        let store = store
        return SessionExport(summary: s, formatter: prefs.formatter) { id in
            try await store.session(for: id)
        }
    }

    private func preview(_ s: SessionSummary) -> SharePreview<Image, Never> {
        SharePreview(s.name, image: Image(systemName: "waveform.path.ecg"))
    }
}

// MARK: - Tag editor

/// Add, remove and reorder a session's tags; recent tags from other sessions
/// are offered as one-tap suggestions.
struct TagEditorSheet: View {
    @State var tags: [String]
    let suggestions: [String]
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @FocusState private var fieldFocused: Bool

    private var available: [String] {
        suggestions.filter { s in !tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New tag", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($fieldFocused)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(trimmed.isEmpty)
                    }
                }
                Section("Tags") {
                    if tags.isEmpty {
                        Text("No tags yet").foregroundStyle(.secondary)
                    }
                    ForEach(tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                    }
                    .onDelete { tags.remove(atOffsets: $0) }
                    .onMove { tags.move(fromOffsets: $0, toOffset: $1) }
                }
                if !available.isEmpty {
                    Section("Recent") {
                        ForEach(available, id: \.self) { tag in
                            Button { tags.append(tag) } label: {
                                Label(tag, systemImage: "plus.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        add()
                        onSave(tags)
                        dismiss()
                    }
                }
            }
            .onAppear { fieldFocused = tags.isEmpty }
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmed: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        let t = trimmed
        guard !t.isEmpty else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            tags.append(t)
        }
        newTag = ""
    }
}
