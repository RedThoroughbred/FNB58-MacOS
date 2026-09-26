import SwiftUI

/// The Sessions tab: an inset-grouped list grouped by day, searchable over
/// name / device / tags / notes, sortable, with swipe, context-menu and
/// multi-select actions. Detail screens are pushed through
/// `AppRouter.sessionPath` so deep links can open a session later.
struct SessionsListView: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(MeterManager.self) private var meter
    @Environment(Preferences.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendar) private var calendar

    @AppStorage("sessions.sort") private var sortRaw = SortOrder.newest.rawValue
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var renameTarget: SessionSummary?
    @State private var renameText = ""
    @State private var pendingDelete: [SessionSummary]?
    @State private var showDiscardInterrupted = false
    @State private var deleteCount = 0
    @State private var errorMessage: String?

    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .newest }

    private var visible: [SessionSummary] {
        SessionQuery.sorted(SessionQuery.filter(store.summaries, query: query), by: sort)
    }

    private var feedbackEnabled: Bool { !reduceMotion && prefs.hapticsEnabled }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.sessionPath) {
            content
                .navigationTitle("Sessions")
                .navigationDestination(for: UUID.self) { id in SessionDetailView(id: id) }
                .toolbar { toolbar }
                .searchable(text: $query, prompt: "Name, device, tag or note")
                .searchSuggestions { suggestions }
                .refreshable { store.load() }
                .safeAreaInset(edge: .top) {
                    if let errorMessage {
                        SessionErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    }
                }
                .alert("Rename Session", isPresented: renamePresented, presenting: renameTarget) { s in
                    TextField("Name", text: $renameText)
                    Button("Rename") { rename(s) }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog(deleteTitle, isPresented: deletePresented, titleVisibility: .visible,
                                    presenting: pendingDelete) { targets in
                    Button(targets.count == 1 ? "Delete Session" : "Delete \(targets.count) Sessions",
                           role: .destructive) { delete(targets) }
                } message: { _ in
                    Text("This removes the recording and its samples. This cannot be undone.")
                }
                .confirmationDialog("Discard the interrupted recording?", isPresented: $showDiscardInterrupted,
                                    titleVisibility: .visible) {
                    Button("Discard Recording", role: .destructive) { discardInterrupted() }
                } message: {
                    Text("Its samples are deleted. This cannot be undone.")
                }
                .onChange(of: editMode.isEditing) { _, editing in
                    if !editing { selection.removeAll() }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: deleteCount) { _, _ in feedbackEnabled }
                .sensoryFeedback(.selection, trigger: sortRaw) { _, _ in feedbackEnabled }
                .saveFeedback(store)
                .environment(\.editMode, $editMode)
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if store.summaries.isEmpty && store.interrupted == nil {
            ContentUnavailableView {
                Label("No Sessions Yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(store.loadError ?? "Recordings you save from the Live tab appear here, grouped by day.")
            } actions: {
                Button("Go to Live") { router.tab = .live }
                    .buttonStyle(.borderedProminent)
                if !meter.state.isConnected {
                    Button("Try Demo Data") {
                        meter.startDemo()
                        router.tab = .live
                    }
                }
            }
        } else if visible.isEmpty && store.interrupted == nil {
            ContentUnavailableView.search(text: query)
        } else {
            list
        }
    }

    private var list: some View {
        // The selection binding is only handed to the List while editing:
        // with it always present, a tap selects the row instead of pushing
        // the NavigationLink.
        List(selection: editMode.isEditing ? $selection : nil) {
            if let interrupted = store.interrupted {
                interruptedSection(interrupted)
            }
            if let loadError = store.loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(SessionQuery.group(visible, calendar: calendar), id: \.day) { group in
                Section {
                    ForEach(group.sessions) { s in
                        NavigationLink(value: s.id) { SessionRow(summary: s) }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { beginRename(s) } label: { Label("Rename", systemImage: "pencil") }
                                    .tint(.orange)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = [s] } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                ShareLink(item: export(s), preview: preview(s)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                rowMenu(s)
                            } preview: {
                                SessionPreviewCard(summary: s)
                            }
                    }
                } header: {
                    dayHeader(group.day)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// A recording that was still running when the app last quit: the
    /// `RecoverySheet` choices (keep as a recovered session, or discard)
    /// inline at the top of the list, so nothing modal blocks the tab.
    private func interruptedSection(_ s: SessionSummary) -> some View {
        Section {
            SessionRow(summary: s)
            HStack(spacing: 12) {
                Button {
                    keepInterrupted()
                } label: {
                    Label("Keep", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    showDiscardInterrupted = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .padding(.vertical, 4)
        } header: {
            Label("Interrupted Recording", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } footer: {
            Text("This recording was still running when WattBench last quit. Keep it as a recovered session or discard it.")
        }
        .selectionDisabled()
    }

    private func dayHeader(_ day: Date) -> some View {
        Group {
            if let name = SessionQuery.relativeDayName(for: day, calendar: calendar) {
                Text(name)
            } else {
                Text(day, format: .dateTime.weekday(.wide).month().day())
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let tags = SessionQuery.recentTags(store.summaries).filter { tag in
            trimmed.isEmpty
                || (tag.localizedCaseInsensitiveContains(trimmed) && tag.caseInsensitiveCompare(trimmed) != .orderedSame)
        }
        if !tags.isEmpty {
            Section("Recent tags") {
                ForEach(tags, id: \.self) { tag in
                    Label(tag, systemImage: "tag")
                        .searchCompletion(tag)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if meter.recording != nil { RecordingStatusChip() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !editMode.isEditing {
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(SortOrder.allCases) { order in
                            Label(order.title, systemImage: order.symbolName).tag(order.rawValue)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            EditButton()
        }
        if editMode.isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(role: .destructive) {
                    pendingDelete = selectedSummaries
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Text(selection.isEmpty ? "Select sessions" : "\(selection.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                ShareLink(items: selectedSummaries.map(export)) { item in
                    SharePreview(item.summary.name, image: Image(systemName: "waveform.path.ecg"))
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ s: SessionSummary) -> some View {
        Button { beginRename(s) } label: { Label("Rename", systemImage: "pencil") }
        ShareLink(item: export(s), preview: preview(s)) {
            Label("Share CSV", systemImage: "square.and.arrow.up")
        }
        Button {
            UIPasteboard.general.string = export(s).summaryText
        } label: {
            Label("Copy Summary", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { pendingDelete = [s] } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Actions

    private var selectedSummaries: [SessionSummary] {
        visible.filter { selection.contains($0.id) }
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

    private func beginRename(_ s: SessionSummary) {
        renameText = s.name
        renameTarget = s
    }

    private func rename(_ s: SessionSummary) {
        do {
            try store.rename(id: s.id, to: renameText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ targets: [SessionSummary]) {
        for s in targets {
            store.delete(id: s.id)
            selection.remove(s.id)
        }
        deleteCount += 1
    }

    private func keepInterrupted() {
        do {
            try store.keepInterrupted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardInterrupted() {
        store.discardInterrupted()
        deleteCount += 1
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return n == 1 ? "Delete this session?" : "Delete \(n) sessions?"
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// Inline error under the navigation bar (errors are never alerts unless
/// they confirm a destructive action). Tap to dismiss; clears itself.
struct SessionErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.red)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floatingChrome(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .onTapGesture(perform: dismiss)
            .task {
                try? await Task.sleep(for: .seconds(5))
                dismiss()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
