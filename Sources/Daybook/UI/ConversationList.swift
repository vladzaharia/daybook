import DaybookCore
import DaybookKit
import SwiftUI
import UniformTypeIdentifiers

/// The list column: conversations in the selected place, or search results.
struct ConversationList: View {
    @ObservedObject var state: AppState
    @State private var isDropTargeted = false

    private var selection: Binding<Set<UUID>> {
        Binding(get: {
            !state.multiSelection.isEmpty ? state.multiSelection : Set(state.selectedID.map { [$0] } ?? [])
        }, set: { ids in
            if ids.count > 1 { state.multiSelection = ids }
            else { state.multiSelection = []; state.selectedID = ids.first }
        })
    }

    var body: some View {
        Group {
            if state.isSearching { results } else { browsing }
        }
        .navigationTitle(title)
        // The subtitle follows a download's percent without redrawing the list.
        .modifier(ListSubtitle(download: state.downloadActivity) { subtitle })
        .safeAreaInset(edge: .top, spacing: 0) { LibraryNotice(state: state) }
        .overlay { if isDropTargeted { DropOutline(label: "Import Audio") } }
        .dropDestination(for: URL.self) { urls, _ in importAudio(urls) } isTargeted: { isDropTargeted = $0 }
        .onDeleteCommand { state.trashRequestIDs = Array(selection.wrappedValue) }
    }

    // MARK: Browsing

    private var browsing: some View {
        let meetings = state.visibleMeetings
        return List(selection: selection) {
            ForEach(DateGroup.groups(for: meetings)) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        // Only the row being processed follows its progress; the others watch an activity that never moves.
                        ActivityReader(processing: state.processingID == meeting.id ? state.processingActivity : nil) {
                            ConversationRow(meeting: meeting, status: RowStatus(state: state, meeting: meeting),
                                            timeLabel: RowDate.format(meeting.date, group: group.title),
                                            selected: selection.wrappedValue.contains(meeting.id))
                        }
                            .tag(meeting.id)
                            .draggable(meeting.id.uuidString)
                            .listRowSeparator(.hidden)
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .softTopScrollEdge()
        .motion(state.isReady ? Motion.state : .linear(duration: 0), value: meetings.map(\.id))
        .contextMenu(forSelectionType: UUID.self) { ids in
            RowMenu(state: state, ids: Array(ids))
        } primaryAction: { ids in
            if let id = ids.first { state.selectedID = id; state.focusTitle(id) }
        }
        .overlay { if meetings.isEmpty && state.isReady { emptyPlace } }
    }

    /// The column's title already names the place, so an empty one just says so (and, for a folder,
    /// how to fill it). An empty library says it once, on the page beside the column.
    @ViewBuilder private var emptyPlace: some View {
        switch state.place {
        case .section(let section):
            if section == .all && state.meetings.isEmpty { Color.clear }
            else { ContentUnavailableView("No Conversations", systemImage: section.systemImage) }
        case .folder:
            ContentUnavailableView("No Conversations", systemImage: "folder",
                                   description: Text("Drag conversations here, or choose Move to Folder."))
        case .device:
            Color.clear
        }
    }

    // MARK: Search

    private var results: some View {
        let hits = state.searchHits
        let byID = Dictionary(state.meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List(selection: Binding(get: { state.selectedID }, set: { id in open(id, in: hits) })) {
            Picker("Search in", selection: $state.searchScope) {
                Text("All").tag(SearchScope.all)
                Text("Work").tag(SearchScope.work)
                Text("Personal").tag(SearchScope.personal)
                if case .folder(let id) = state.place, let folder = state.folders.first(where: { $0.id == id }) {
                    Text(folder.name).tag(SearchScope.folder(id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Space.s3)
            .selectionDisabled()
            .listRowSeparator(.hidden)
            // The control's edges line up with the result rows' highlight.
            .listRowInsets(EdgeInsets())
            .padding(.horizontal, -6.5)
            ForEach(hits) { hit in
                if let meeting = byID[hit.meetingID] {
                    SearchResultRow(meeting: meeting, hit: hit).tag(hit.meetingID).listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.inset)
        .softTopScrollEdge()
        .overlay { if hits.isEmpty { ContentUnavailableView.search(text: state.search) } }
    }

    private func open(_ id: UUID?, in hits: [SearchHit]) {
        state.multiSelection = []
        state.selectedID = id
        guard let hit = hits.first(where: { $0.meetingID == id }) else { return }
        if hit.field == .transcript, let segment = hit.segmentID {
            state.pageMode = .transcript
            state.pageScrollTarget = segment
        } else {
            state.pageMode = .summary
        }
    }

    // MARK: Title and status

    private var title: String {
        switch state.place {
        case .section(let section): return section.rawValue
        case .folder(let id): return state.folders.first { $0.id == id }?.name ?? "Folder"
        case .device(let id): return state.devices.session(id)?.device.name ?? "Device"
        }
    }

    /// Says something only while work is happening.
    private var subtitle: String {
        if state.isSearching {
            let count = state.searchHits.count
            return count == 1 ? "1 result" : "\(count) results"
        }
        if state.multiSelection.count > 1 { return "\(state.multiSelection.count) selected" }
        if state.isStoppingRecording { return "Saving recording…" }
        if state.isRecording { return "Recording" }
        if state.processingID != nil {
            let total = state.queuedIDs.count + 1
            return total > 1 ? "Transcribing 1 of \(total)" : "Transcribing"
        }
        if state.downloadingID != nil { return "Downloading models · \(Int(state.downloadProgress.fraction * 100))%" }
        return ""
    }

    private func importAudio(_ urls: [URL]) -> Bool {
        let audio = AppState.droppedRecordings(urls)
        guard !audio.isEmpty else { return false }
        Task { do { try await state.importFiles(audio, source: .imported, attachTo: nil) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
        return true
    }
}

/// The list's subtitle, redrawn by a download's progress on its own.
private struct ListSubtitle: ViewModifier {
    @ObservedObject var download: ActivityProgress
    let text: () -> String

    func body(content: Content) -> some View { content.navigationSubtitle(text()) }
}

// MARK: - Rows

/// What a row says about a conversation that isn't ready; nil when everything is fine.
struct RowStatus {
    enum Kind { case recording, processing, waiting, waitingForModels, paused, failed, notTranscribed }
    let kind: Kind?
    let text: String?
    /// How far processing has got, for the row's progress line.
    var fraction: Double = 0

    /// Recording is this Mac's own state; everything else reads from `ProcessingStatus`, which the
    /// conversation page and the iPhone share.
    @MainActor init(state: AppState, meeting: Meeting) {
        if state.recordingID == meeting.id { kind = .recording; text = "Recording now"; return }
        switch state.processingStatus(for: meeting) {
        case .processing(let progress):
            kind = .processing
            fraction = progress.fraction ?? 0
            let verb = progress.stage == .summarizing ? "Summarizing" : "Transcribing"
            if let device = progress.device { text = "\(verb) on \(device.name)" }
            else { text = progress.stage == .summarizing ? "Summarizing…" : "Transcribing · \(Int(fraction * 100))%" }
        case .requested(.queued): kind = .waiting; text = state.requestOrigin(for: meeting) ?? "Waiting"
        case .requested(.models): kind = .waitingForModels; text = "Waiting for models"
        case .requested(.paused): kind = .paused; text = "Paused"
        case .requested(.device(let request)): kind = .waiting; text = "Requested from \(request.requestedBy.name)"
        case .failed: kind = .failed; text = "Couldn’t finish"
        case .recorded: kind = .notTranscribed; text = "Not transcribed yet"
        case .done: kind = nil; text = nil
        }
    }
}

struct ConversationRow: View {
    let meeting: Meeting
    let status: RowStatus
    let timeLabel: String
    var selected = false
    @State private var hovering = false
    @State private var justFinished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meeting.title.isEmpty ? "Untitled Conversation" : meeting.title)
                    .font(TypeStyle.rowTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                glyph
                    .font(.system(size: 11, weight: .semibold))
                    .transition(.opacity)
            }
            // Apple Notes' list: the date reads first, the preview recedes but stays legible.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(timeLabel).foregroundStyle(.primary)
                Text(status.text ?? preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .font(TypeStyle.rowDetail)
            .animation(.easeOut(duration: 0.2), value: status.text)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(Color.primary.opacity(hovering && !selected ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .animation(hovering ? Motion.hover : .easeOut(duration: 0.2), value: hovering)
        .onChange(of: status.kind) { old, new in
            // A checkmark holds for a moment when work finishes, so the row says it's done.
            guard old == .processing, new == nil else { return }
            justFinished = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) { justFinished = false }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([meeting.title, timeLabel, meeting.duration.map(DurationLabel.format), status.text].compactMap { $0 }.joined(separator: ", "))
    }

    private var preview: String { RowPreview.text(for: meeting) }

    @ViewBuilder private var glyph: some View {
        switch status.kind {
        case .recording?:
            Image(systemName: "record.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(Ink.record)
                .symbolEffect(.breathe, options: reduceMotion ? .nonRepeating : .repeating)
                .neonGlow(Ink.record, radius: 3)
        case .processing?:
            // One moving neon line says "working" in the densest grey surface, without words.
            ProgressView(value: status.fraction).progressViewStyle(.brand(width: 44, height: 2))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case .waiting?: Image(systemName: "clock").foregroundStyle(.secondary)
        case .waitingForModels?: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .paused?: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        case .failed?: Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.monochrome).foregroundStyle(Ink.warning)
        case .notTranscribed?: Circle().fill(DaybookStyle.accent).frame(width: 7, height: 7)
        case nil:
            if justFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DaybookStyle.accent)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
            }
        }
    }
}

private struct SearchResultRow: View {
    let meeting: Meeting
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.rowTitle).lineLimit(1)
                Spacer(minLength: 6)
                Text(meeting.date.formatted(.dateTime.day().month(.abbreviated))).font(TypeStyle.rowDetail).foregroundStyle(.secondary)
            }
            if hit.field != .title || hit.match == nil {
                Text(snippet).font(TypeStyle.rowDetail).foregroundStyle(.secondary).lineLimit(2)
            }
            Label {
                Text(location)
            } icon: {
                Image(systemName: locationSymbol).font(.system(size: 10))
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var locationSymbol: String {
        switch hit.field {
        case .title: return "textformat"
        case .summary: return "text.alignleft"
        case .notes: return "note.text"
        case .transcript: return "quote.bubble"
        }
    }

    private var snippet: AttributedString { Self.marked(hit.snippet, match: hit.match, weight: .semibold, size: 12) }

    /// A title match is marked in the title itself, as a snippet's is in the snippet.
    private var title: AttributedString {
        let text = meeting.title.isEmpty ? "Untitled Conversation" : meeting.title
        guard hit.field == .title, let match = hit.match, text == hit.snippet else { return AttributedString(text) }
        return Self.marked(text, match: match, weight: .bold, size: 13)
    }

    private static func marked(_ string: String, match: Range<String.Index>?, weight: Font.Weight, size: CGFloat) -> AttributedString {
        var text = AttributedString(string)
        if let match, let lower = AttributedString.Index(match.lowerBound, within: text),
           let upper = AttributedString.Index(match.upperBound, within: text) {
            text[lower..<upper].font = .system(size: size, weight: weight)
            text[lower..<upper].foregroundColor = Ink.link
        }
        return text
    }

    private var location: String {
        switch hit.field {
        case .title: return hit.match == nil ? "Conversation" : "Title"
        case .summary: return "Summary"
        case .notes: return "Your notes"
        case .transcript:
            if hit.matchCount > 1 { return "Transcript · \(hit.matchCount) matches" }
            return (["Transcript", hit.speaker, hit.time.map(TimeLabel.short)].compactMap { $0 }).joined(separator: " · ")
        }
    }
}

/// Actions for one or more selected rows. Items that don't apply are hidden.
private struct RowMenu: View {
    @ObservedObject var state: AppState
    let ids: [UUID]
    private var meetings: [Meeting] { state.meetings.filter { ids.contains($0.id) } }

    var body: some View {
        if let meeting = meetings.first, meetings.count == 1 {
            Button("Rename") { state.selectedID = meeting.id; state.focusTitle(meeting.id) }
            Menu("Move to Folder") { FolderMenuItems(state: state, meetingIDs: ids) }
            placementButton
            Divider()
            ReprocessMenu(state: state, meeting: meeting)
            Menu("Export") {
                Button("Markdown…") { state.export(meeting.id) }
                Button("Full Data (JSON)…") { state.export(meeting.id, json: true) }
            }
            if meeting.summary != nil { Button("Copy Summary") { state.copySummary(meeting.id) } }
            Button("Show in Finder") { state.showInFinder(meeting.id) }
            Divider()
            Button("Move to Trash…", role: .destructive) { state.trashRequestIDs = ids }
                .disabled(state.recordingID == meeting.id || state.processingID == meeting.id)
        } else if !meetings.isEmpty {
            Menu("Move to Folder") { FolderMenuItems(state: state, meetingIDs: ids) }
            placementButton
            Divider()
            Button("Summarize Again") { for meeting in meetings where !meeting.unifiedTranscript.isEmpty { state.enqueue(meeting.id, mode: .summaryOnly) } }
            Divider()
            Button("Move \(meetings.count) to Trash…", role: .destructive) { state.trashRequestIDs = ids }
        }
    }

    private var placementButton: some View {
        let personal = meetings.allSatisfy { $0.effectivePlacement == .personal }
        return Button(personal ? "Move to Work" : "Move to Personal") { state.setPlacement(ids, personal ? .work : .personal) }
    }
}

// MARK: - Grouping and dates

// `DateGroup`, `RowDate`, and `RowPreview` live in DaybookKit, shared with the iPhone.

// MARK: - Notices and drop targets

/// One library-wide notice at the top of the list column; the newest wins.
private struct LibraryNotice: View {
    @ObservedObject var state: AppState
    var body: some View {
        if let notice = state.notice {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(DaybookStyle.accent)
                Text(notice).font(TypeStyle.status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { withAnimation(.easeOut(duration: 0.2)) { state.notice = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .padding(10)
            .quietBox()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct DropOutline: View {
    let label: String
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DaybookStyle.accent.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DaybookStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                .padding(6)
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(DaybookStyle.accent)
                Text(label).font(.headline)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .scaleEffect(shown || reduceMotion ? 1 : 0.98)
        .opacity(shown ? 1 : 0)
        .onAppear { shown = true }
        .motion(.easeOut(duration: 0.15), value: shown)
        .allowsHitTesting(false)
    }
}

/// Icon and title close together, for small metadata lines.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

private extension View {
    /// A pinned section header blends into the toolbar's soft edge instead of drawing a second rule.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}
