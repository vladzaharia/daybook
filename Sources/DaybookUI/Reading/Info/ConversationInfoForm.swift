import DaybookDesign
import DaybookKit
import SwiftUI

/// A conversation's Info, one form for both apps (docs/interface.md, "Inspector"): Details (folder, tags, where it
/// shows, its template, when it was made and changed), People, Audio, and Processing. The Mac shows it as the
/// window's inspector, its sections collapsing and remembering it; the iPhone as a sheet, and on the open Duo a card
/// on the right page. Labels and values are one size; on the Mac labels recede, under touch each row has its symbol.
/// Folder, tags, where it shows, and a speaker's name can be undone.
public struct ConversationInfoForm<AudioExtras: View, AddRecording: View>: View {
    let library: LibraryController
    let meetingID: UUID
    let services: ConversationInfoServices
    let audioExtras: (Meeting) -> AudioExtras
    let addRecording: (Meeting) -> AddRecording
    @State private var removing: RecordingTrack?
    @Environment(\.daybookDensity) private var density
    @Environment(\.undoManager) private var undoManager
    #if os(macOS)
    @AppStorage("inspector.details") private var detailsExpanded = true
    @AppStorage("inspector.people") private var peopleExpanded = true
    @AppStorage("inspector.audio") private var audioExpanded = false
    @AppStorage("inspector.processing") private var processingExpanded = false
    #endif

    /// - Parameters:
    ///   - audioExtras: What this app adds under the recordings (the Mac's recordings to come and suggestions).
    ///   - addRecording: This app's Add Recording at the foot of Audio.
    public init(library: LibraryController, meetingID: UUID, services: ConversationInfoServices,
                @ViewBuilder audioExtras: @escaping (Meeting) -> AudioExtras,
                @ViewBuilder addRecording: @escaping (Meeting) -> AddRecording) {
        self.library = library
        self.meetingID = meetingID
        self.services = services
        self.audioExtras = audioExtras
        self.addRecording = addRecording
    }

    public var body: some View {
        if let meeting = library.meeting(meetingID) {
            Form {
                section("Details", expanded: details) { DetailsRows(library: library, meeting: meeting, services: services) }
                // Notes alone have no speakers and nothing processed: those sections wait for audio.
                if !meeting.tracks.isEmpty || !meeting.speakers.isEmpty {
                    section("People", expanded: people) { PeopleSection(library: library, meeting: meeting) }
                        .id(InfoSectionID.people)
                }
                section("Audio", expanded: audio) {
                    AudioSection(meeting: meeting, services: services, removing: $removing) {
                        audioExtras(meeting)
                    } addRecording: {
                        addRecording(meeting)
                    }
                }
                .id(InfoSectionID.audio)
                if !meeting.tracks.isEmpty || !meeting.revisions.isEmpty {
                    section("Processing", expanded: processing) { ProcessingRows(meeting: meeting, services: services) }
                        .id(InfoSectionID.processing)
                }
            }
            .formStyle(.grouped)
            .labeledContentStyle(InfoLabeledStyle())
            .alert(removing.map { "Remove “\(services.recordingName($0, meeting))”?" } ?? "",
                   isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                   presenting: removing) { track in
                Button("Remove Recording", role: .destructive) {
                    removing = nil
                    services.perform(.track(.removeRecording, track), meeting)
                }
                Button("Cancel", role: .cancel) { removing = nil }
                    .keyboardShortcut(.defaultAction)
            } message: { _ in
                Text("Its words leave the transcript. You can put it back.")
            }
        } else {
            ContentUnavailableView("Conversation Not Found", systemImage: "doc.questionmark")
        }
    }

    // Collapsible on the Mac, remembered; under touch, always open.
    #if os(macOS)
    private var details: Binding<Bool>? { $detailsExpanded }
    private var people: Binding<Bool>? { $peopleExpanded }
    private var audio: Binding<Bool>? { $audioExpanded }
    private var processing: Binding<Bool>? { $processingExpanded }
    #else
    private var details: Binding<Bool>? { nil }
    private var people: Binding<Bool>? { nil }
    private var audio: Binding<Bool>? { nil }
    private var processing: Binding<Bool>? { nil }
    #endif

    @ViewBuilder private func section<Content: View>(_ title: String, expanded: Binding<Bool>?, @ViewBuilder _ content: () -> Content) -> some View {
        if let expanded {
            Section(title, isExpanded: expanded) { content() }
        } else {
            Section(title) { content() }
        }
    }
}

/// Where Info can be scrolled to (`--info-scroll people`, for screenshots).
public enum InfoSectionID: String, Hashable, Sendable {
    case people, audio, processing
}

// MARK: - Details

private struct DetailsRows: View {
    let library: LibraryController
    let meeting: Meeting
    let services: ConversationInfoServices
    @Environment(\.undoManager) private var undoManager
    @Environment(\.daybookDensity) private var density

    var body: some View {
        Picker(selection: Binding(get: { meeting.folderID }, set: { folder in
            library.update(meeting.id, actionName: "Move to Folder", undoManager: undoManager) { $0.folderID = folder }
        })) {
            Text("None").tag(UUID?.none)
            if !library.folders.isEmpty { Divider() }
            ForEach(library.folders) { folder in Text(folder.name).tag(UUID?.some(folder.id)) }
        } label: { InfoRowLabel("Folder", symbol: "folder") }
            .infoControl()
        tags
        Picker(selection: Binding(get: { PlacementChoice(meeting.placement) }, set: { choice in
            library.update(meeting.id, actionName: choice.actionName, undoManager: undoManager) { $0.placement = choice.placement }
        })) {
            Text(meeting.automaticPlacementTitle).tag(PlacementChoice.automatic)
            Divider()
            Text("Work").tag(PlacementChoice.work)
            Text("Personal").tag(PlacementChoice.personal)
        } label: { InfoRowLabel("Shows in", symbol: "rectangle.stack") }
            .infoControl()
        Picker(selection: Binding(get: { library.templateSelection(for: meeting.id) }, set: chooseTemplate)) {
            Text(TemplateWords.automatic(for: meeting)).tag("auto")
            Divider()
            ForEach(library.templates.filter(\.isBuiltIn)) { template in Text(template.name).tag(template.id) }
            let custom = library.templates.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { template in Text(template.name).tag(template.id) }
            }
        } label: { InfoRowLabel("Template", symbol: "doc.text") }
            .infoControl()
        LabeledContent { Text(InfoDate.format(meeting.date)) } label: { InfoRowLabel("Created", symbol: "calendar") }
        LabeledContent { Text(InfoDate.format(meeting.updatedAt)) } label: { InfoRowLabel("Edited", symbol: "pencil") }
    }

    /// Like Finder's Get Info: the label, then the chips starting on the label's edge.
    @ViewBuilder private var tags: some View {
        let editor = TagEditor(tags: meeting.tags ?? [], save: saveTags) { tag in services.perform(.searchTag(tag), meeting) }
        if density == .touch {
            Label {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tags")
                    editor
                }
            } icon: {
                // Beside "Tags", not halfway down the chips.
                InfoSymbol("tag").frame(maxHeight: .infinity, alignment: .top).padding(.top, 2)
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").foregroundStyle(.secondary)
                editor
            }
        }
    }

    private func saveTags(_ tags: [String]) {
        let before = meeting.tags ?? []
        let name = tags.count < before.count ? "Remove Tag" : "Add Tag"
        library.update(meeting.id, actionName: name, undoManager: undoManager) { $0.tags = tags }
    }

    /// Choosing a different template summarizes again; the earlier summary stays in Version History. It starts work,
    /// so it isn't undone from Edit › Undo.
    private func chooseTemplate(_ id: String) {
        guard library.chooseTemplate(id, for: meeting.id), let after = library.meeting(meeting.id), !after.unifiedTranscript.isEmpty else { return }
        services.perform(.summarize(templateID: id == "auto" ? nil : id), after)
    }
}

/// Shows in: automatic (with its guess), Work, or Personal.
private enum PlacementChoice: Hashable {
    case automatic, work, personal

    init(_ placement: LibraryPlacement?) {
        switch placement {
        case .work?: self = .work
        case .personal?: self = .personal
        case nil: self = .automatic
        }
    }

    var placement: LibraryPlacement? {
        switch self {
        case .automatic: return nil
        case .work: return .work
        case .personal: return .personal
        }
    }

    var actionName: String {
        switch self {
        case .automatic: return "Show Automatically"
        case .work: return "Move to Work"
        case .personal: return "Move to Personal"
        }
    }
}

// MARK: - Processing

private struct ProcessingRows: View {
    let meeting: Meeting
    let services: ConversationInfoServices
    @Environment(\.daybookDensity) private var density

    var body: some View {
        NowRow(meeting: meeting, services: services)
        if let run = meeting.transcripts.max(by: { $0.createdAt < $1.createdAt }) {
            LabeledContent {
                Text(services.catalog.name(for: run.modelID, provenance: run.processingSettings?.model))
            } label: {
                Text("Transcribed")
                Text(InfoDate.format(run.createdAt))
            }
        }
        // Which model found the speakers; "Not identified" only for a transcript that has none.
        if let settings = meeting.speakers.compactMap(\.analysisSettings).first {
            LabeledContent("Speakers", value: services.catalog.name(for: settings.modelID, provenance: settings.model))
        } else if !meeting.transcripts.isEmpty && meeting.speakers.isEmpty {
            LabeledContent("Speakers", value: "Not identified")
        }
        if let summary = meeting.summary { summaryRow(summary) }
        actions
    }

    /// The model that wrote the summary; a cloud model's with what it used and cost ("12,700 tokens · $0.05").
    private func summaryRow(_ summary: MeetingSummary) -> some View {
        let cloud = summary.cloudProvenance
        let when = InfoDate.format(summary.createdAt)
        let row = LabeledContent {
            Text(cloud?.name ?? services.catalog.name(for: summary.modelID, provenance: summary.processingSettings?.model))
        } label: {
            Text("Summary")
            Text(cloud?.usage ?? when)
        }
        #if os(macOS)
        let words = services.words
        return row.help([summary.origin.colophon(thisDeviceID: words.thisDeviceID ?? "", thisDevice: words.here, unknown: words.unknown), when]
            .joined(separator: " · "))
        #else
        return row
        #endif
    }

    @ViewBuilder private var actions: some View {
        let groups = ConversationActions.actions(for: meeting, context: services.actionContext(meeting))
        let reprocess = groups.first { $0.id == .reprocess }?.actions.first
        let history = groups.first { $0.id == .history }?.actions.first
        if density == .touch {
            if let reprocess, reprocess.isAvailable { ReprocessMenu(action: reprocess, meeting: meeting, services: services) }
            if let history, history.isAvailable {
                Button { services.perform(.versionHistory, meeting) } label: {
                    Label(history.title.replacingOccurrences(of: "…", with: ""), systemImage: history.symbol)
                }
            }
        } else if !meeting.tracks.isEmpty || !meeting.revisions.isEmpty {
            HStack {
                if let reprocess, !meeting.tracks.isEmpty {
                    ReprocessMenu(action: reprocess, meeting: meeting, services: services)
                        .menuStyle(.button)
                        .controlSize(.small)
                        .fixedSize()
                }
                Spacer()
                if let history, history.isAvailable {
                    Button(history.title) { services.perform(.versionHistory, meeting) }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Reprocess ▸ the modes that apply (`ConversationActions`): dimmed on the Mac when they can't run now, left out
/// under touch.
private struct ReprocessMenu: View {
    let action: ConversationAction
    let meeting: Meeting
    let services: ConversationInfoServices
    @Environment(\.daybookDensity) private var density

    var body: some View {
        let touch = density == .touch
        Menu {
            ForEach(action.children.filter { !touch || $0.isAvailable }) { mode in
                if case .process(let request) = mode.id {
                    Button { services.perform(.process(request), meeting) } label: { Label(mode.title, systemImage: mode.symbol) }
                        .disabled(!mode.isAvailable)
                }
            }
        } label: {
            if touch { Label(action.title, systemImage: action.symbol) } else { Text(action.title) }
        }
        .disabled(!action.isAvailable)
    }
}

/// What's happening now, in the list row's words, with what can be done about it there; a countdown moves a second
/// at a time.
private struct NowRow: View {
    let meeting: Meeting
    let services: ConversationInfoServices

    var body: some View {
        if let now = services.now(meeting, Date()) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    if now.countdownUntil != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(services.now(meeting, context.date)?.text(at: context.date) ?? now.text).monospacedDigit()
                        }
                    } else {
                        Text(now.text)
                    }
                    if !now.actions.isEmpty {
                        FlowLayout(spacing: 10, alignment: .trailing) {
                            ForEach(now.actions, id: \.title) { action in
                                Button(action.title) { services.perform(.status(action), meeting) }
                                    .buttonStyle(.daybookLink)
                            }
                        }
                    }
                }
                .multilineTextAlignment(.trailing)
            } label: {
                InfoRowLabel("Now", symbol: "clock")
            }
        }
    }
}

// MARK: - Labels

/// A row's name; under touch with its symbol, in the secondary ink: symbols in Info describe, they aren't actions.
struct InfoRowLabel: View {
    let title: String
    let symbol: String
    @Environment(\.daybookDensity) private var density

    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }

    var body: some View {
        if density == .touch {
            Label { Text(title) } icon: { InfoSymbol(symbol) }
        } else {
            Text(title)
        }
    }
}

struct InfoSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View { Image(systemName: name).foregroundStyle(DaybookPalette.Ink.secondary) }
}

/// Labels recede so the values lead, on the Mac (as its inspectors do); under touch they keep the label ink.
private struct InfoLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View { InfoLabeled(configuration: configuration) }
}

private struct InfoLabeled: View {
    let configuration: LabeledContentStyleConfiguration
    @Environment(\.daybookDensity) private var density

    var body: some View {
        if density == .touch {
            LabeledContent { configuration.content } label: { configuration.label }
        } else {
            LabeledContent { configuration.content } label: { configuration.label.foregroundStyle(.secondary) }
        }
    }
}

extension View {
    /// A picker or menu in Info: the Mac's small control (its values stay the row's size); unchanged under touch.
    func infoControl() -> some View { macControlSize(.small) }
}
