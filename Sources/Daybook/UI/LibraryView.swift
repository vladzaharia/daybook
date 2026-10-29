import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window: places, the conversation list, and the page, with an optional inspector.
struct LibraryView: View {
    @ObservedObject var state: AppState
    @AppStorage("isInspectorPresented") private var inspectorPresented = false
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var autoCollapsedSidebar = false
    @State private var windowWidth: CGFloat = 1280
    @State private var problemDetails: AppProblem?
    @FocusState private var searchFocused: Bool

    /// The conversation whose controls the toolbar shows; on the device page, an imported recording's conversation.
    private var toolbarMeeting: Meeting? {
        guard state.multiSelection.count < 2 else { return nil }
        if state.place.isDevice && !state.isSearching {
            return state.deviceConversationID.flatMap { id in state.meetings.first { $0.id == id } }
        }
        return state.selectedMeeting
    }

    private var showsConversation: Bool { !state.place.isDevice && state.multiSelection.count < 2 && state.selectedMeeting != nil }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            Group {
                if state.place.isDevice && !state.isSearching { DeviceRecordingsList(state: state) }
                else { ConversationList(state: state) }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
                .toolbar { DetailToolbar(state: state, meeting: toolbarMeeting, inspectorPresented: $inspectorPresented) }
                .inspector(isPresented: Binding(get: { inspectorPresented && showsConversation }, set: { inspectorPresented = $0 })) {
                    if let id = state.selectedID {
                        MeetingInspector(state: state, meetingID: id)
                            .inspectorColumnWidth(min: 260, ideal: 280, max: 340)
                    }
                }
        }
        .searchable(text: $state.search, tokens: $state.searchTokens, placement: .toolbar, prompt: "Titles, Notes, Transcripts") { token in
            switch token {
            case .tag(let tag): Label(tag, systemImage: "number")
            case .speaker(let name): Label(name, systemImage: "person")
            }
        }
        .searchSuggestions { suggestions }
        .searchFocused($searchFocused)
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: state.search) { _, text in promoteHashTag(text) }
        .onChange(of: state.place) { _, _ in reconcileSelection() }
        .onChange(of: state.visibleMeetings.map(\.id)) { _, _ in reconcileSelection() }
        .environment(\.readingScale, CGFloat(state.readingScale))
        .tint(DaybookStyle.accent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0; adaptColumns() }
        .onChange(of: inspectorPresented) { _, _ in adaptColumns() }
        .onChange(of: showsConversation) { _, _ in adaptColumns() }
        .sheet(item: $state.activeSheet) { sheet in ConversationSheet(state: state, sheet: sheet) }
        .sheet(item: $state.addDeviceRequest) { request in AddDeviceSheet(state: state, request: request) }
        .sheet(item: $state.libraryMoveOffer) { offer in LibraryMoveSheet(state: state, offer: offer) }
        .alert(trashTitle, isPresented: Binding(get: { !state.trashRequestIDs.isEmpty }, set: { if !$0 { state.trashRequestIDs = [] } })) {
            Button("Move to Trash", role: .destructive) {
                for id in state.trashRequestIDs { state.trashMeeting(id) }
                state.multiSelection = []
                state.trashRequestIDs = []
            }
            Button("Cancel", role: .cancel) { state.trashRequestIDs = [] }
        } message: {
            Text(state.trashRequestIDs.count > 1 ? "Their audio, notes, and summaries go with them."
                 : "Its audio, notes, and summary go with it.")
        }
        .alert(state.shownProblem?.title ?? "", isPresented: Binding(get: { state.shownProblem != nil }, set: { if !$0 { state.dismissProblem() } }),
               presenting: state.shownProblem) { problem in
            Button("OK") { state.dismissProblem() }
            if problem.details != nil {
                Button("Details…") { problemDetails = problem; state.dismissProblem() }
            }
        } message: { problem in Text(problem.message) }
        .sheet(item: $problemDetails) { ProblemDetailsSheet(problem: $0) }
    }

    @ViewBuilder private var detail: some View {
        if state.place.isDevice && !state.isSearching {
            DevicePage(state: state)
        } else if state.multiSelection.count > 1 {
            BatchSelectionView(state: state, ids: Array(state.multiSelection))
        } else if let meeting = state.selectedMeeting {
            MeetingDetailView(state: state, meetingID: meeting.id)
                .id(meeting.id)
                .modifier(AddRecordingDrop(state: state, meeting: meeting))
        } else if state.isReady && state.meetings.isEmpty {
            EmptyLibraryView(state: state)
        } else if !state.isSearching && state.visibleMeetings.isEmpty {
            // An empty place says so in its list; the page stays blank rather than asking for a choice.
            DaybookStyle.paper
        } else {
            Text("No Conversation Selected")
                .font(TypeStyle.heading())
                .foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DaybookStyle.paper)
        }
    }

    private var trashTitle: String {
        let ids = state.trashRequestIDs
        if ids.count > 1 { return "Move \(ids.count) conversations to the Trash?" }
        let title = ids.first.flatMap { id in state.meetings.first { $0.id == id }?.title } ?? "this conversation"
        return "Move “\(title)” to the Trash?"
    }

    @ViewBuilder private var suggestions: some View {
        let text = state.search.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            let query = text.dropFirst().lowercased()
            ForEach(state.allTags.filter { query.isEmpty || $0.lowercased().hasPrefix(query) }, id: \.self) { tag in
                Label(tag, systemImage: "number").searchCompletion(SearchToken.tag(tag))
            }
        } else if !text.isEmpty {
            let names = Set(state.meetings.flatMap(\.speakers).map(\.name).filter { !$0.hasPrefix("Speaker ") && $0.lowercased().hasPrefix(text.lowercased()) })
            ForEach(names.sorted(), id: \.self) { name in
                Label(name, systemImage: "person").searchCompletion(SearchToken.speaker(name))
            }
        }
    }

    /// The page always shows something in the list: when the selection leaves the place
    /// (moved to another folder, or the place changed), the first visible conversation is selected.
    private func reconcileSelection() {
        guard state.isReady, !state.isSearching, !state.place.isDevice else { return }
        let visible = state.visibleMeetings
        if let selected = state.selectedID, visible.contains(where: { $0.id == selected }) { return }
        state.multiSelection = []
        state.selectedID = visible.first?.id
    }

    /// Typing "#tag " turns the tag into a token.
    private func promoteHashTag(_ text: String) {
        guard text.hasPrefix("#"), text.hasSuffix(" "), let tag = state.allTags.first(where: { "#\($0) " == text }) else { return }
        state.searchTokens.append(.tag(tag))
        state.search = ""
    }

    /// The sidebar steps aside in narrow windows, and when the inspector would leave the page under
    /// 560 pt. It comes back afterwards, unless the person hid it themselves.
    private func adaptColumns() {
        let inspector: CGFloat = inspectorPresented && showsConversation ? 280 : 0
        let crowded = windowWidth < 1000 || windowWidth - 200 - 300 - inspector < 560
        if crowded, columns == .all {
            withAnimation { columns = .doubleColumn }
            autoCollapsedSidebar = true
        } else if !crowded, autoCollapsedSidebar, windowWidth >= 1100 || inspector == 0 {
            withAnimation { columns = .all }
            autoCollapsedSidebar = false
        }
    }
}

// MARK: - Record

/// Record, or the red elapsed-time pill that stops the recording.
struct RecordToolbarItem: ToolbarContent {
    @ObservedObject var state: AppState
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { RecordControl(state: state) }
    }
}

/// Record, then the red elapsed-time pill, then Saving…; each blurs into the next.
private struct RecordControl: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case idle, recording, saving }
    private var phase: Phase {
        if state.isStoppingRecording { return .saving }
        return state.isRecording && state.recordingStartedAt != nil ? .recording : .idle
    }

    var body: some View {
        Group {
            switch phase {
            case .saving:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }
                    .foregroundStyle(.secondary)
            case .recording:
                RecordingPill(state: state, start: state.recordingStartedAt ?? Date())
            case .idle:
                Button { Task { await state.startRecording() } } label: {
                    Label {
                        Text("Record")
                    } icon: {
                        Image(systemName: "record.circle").symbolRenderingMode(.palette).foregroundStyle(Ink.record, .secondary)
                    }
                }
                .disabled(!state.isReady || state.isStartingRecording)
                .help("Start Recording (⇧⌘R)")
            }
        }
        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        .motion(Motion.state, value: phase)
    }
}

private struct RecordingPill: View {
    @ObservedObject var state: AppState
    let start: Date
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { Task { await state.stopRecording() } } label: {
            Label {
                ElapsedTime(start: start)
            } icon: {
                Image(systemName: "stop.fill")
                    .symbolEffect(.bounce.down, options: .nonRepeating, value: reduceMotion ? false : appeared)
            }
            .labelStyle(.titleAndIcon)
        }
        .glassButtonStyle(prominent: true)
        .tint(Ink.recordFill)
        .help("Stop Recording (⇧⌘R)")
        .accessibilityLabel("Stop recording")
        .onAppear { appeared = true }
    }
}

// MARK: - Empty library and multiple selection

private struct EmptyLibraryView: View {
    @ObservedObject var state: AppState
    @State private var isDropTargeted = false
    var body: some View {
        VStack(spacing: Space.s4) {
            DaybookMark(size: 64)
                .padding(.bottom, Space.s2)
            Text("No Conversations Yet").font(TypeStyle.docTitleSmall).foregroundStyle(Ink.title)
            Text("Record a conversation, or drop audio files here.").foregroundStyle(Ink.secondary)
            HStack(spacing: Space.s3) {
                Button { Task { await state.startRecording() } } label: { Label("Record", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
                    .tint(DaybookStyle.prominentFill)
                    .disabled(!state.isReady || state.isStartingRecording)
                Button("Import Audio…") { state.chooseImport() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, Space.s2)
            if let id = state.downloadingID {
                ActivityReader(download: state.downloadActivity) {
                    Text("Downloading \(state.modelCatalog.name(for: id)) · \(Int(state.downloadProgress.fraction * 100))%")
                        .font(TypeStyle.status)
                        .foregroundStyle(Ink.secondary)
                        .padding(.top, Space.s6)
                }
            }
        }
        .offset(y: -24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookStyle.paper)
        .overlay { if isDropTargeted { DropOutline(label: "Import Audio") } }
        .dropDestination(for: URL.self) { urls, _ in
            Task { do { try await state.importFiles(urls, source: .imported, attachTo: nil) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }
}

private struct BatchSelectionView: View {
    @ObservedObject var state: AppState
    let ids: [UUID]
    private var meetings: [Meeting] { state.meetings.filter { ids.contains($0.id) }.sorted { $0.date > $1.date } }
    var body: some View {
        VStack(spacing: Space.s3) {
            Text("\(meetings.count) Conversations").font(TypeStyle.docTitleSmall).foregroundStyle(Ink.title)
            // Up to four names; "and 1 more" would take the place of the one name it hides.
            Text(meetings.count > 4 ? meetings.prefix(3).map(\.title).joined(separator: ", ") + ", and \(meetings.count - 3) more"
                 : meetings.map(\.title).formatted(.list(type: .and)))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Menu("Move to Folder") { FolderMenuItems(state: state, meetingIDs: ids) }.fixedSize()
                Button(meetings.allSatisfy { $0.effectivePlacement == .personal } ? "Move to Work" : "Move to Personal") {
                    state.setPlacement(ids, meetings.allSatisfy { $0.effectivePlacement == .personal } ? .work : .personal)
                }
            }
            .padding(.top, Space.s2)
            // Red is reserved for recording; destructive text takes the error ink.
            Button("Move to Trash…", role: .destructive) { state.trashRequestIDs = ids }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.error)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookStyle.paper)
    }
}

/// Audio dropped on an open conversation joins it as another recording.
private struct AddRecordingDrop: ViewModifier {
    @ObservedObject var state: AppState
    let meeting: Meeting
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay { if targeted { DropOutline(label: "Add to “\(meeting.title)”") } }
            .dropDestination(for: URL.self) { urls, _ in
                let audio = AppState.droppedRecordings(urls)
                guard !audio.isEmpty, state.recordingID != meeting.id else { return false }
                Task { do { try await state.importFiles(audio, source: .imported, attachTo: meeting.id) } catch { state.report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) } }
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// Elapsed recording time that rolls only the digits that change.
struct ElapsedTime: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            Text(TimeLabel.short(elapsed))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .motion(.snappy(duration: 0.3), value: Int(elapsed))
        }
    }
}
