import DaybookKit
import SwiftUI
import UIKit

/// Version History: every change to the notes, the transcript, speaker names, and the summary,
/// newest first, each with what it was before and after, and Restore.
struct VersionHistoryView: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    private let dismiss = SheetDismiss()
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let meeting = library.meeting(meetingID), !meeting.revisions.isEmpty {
                    List {
                        ForEach(groups(meeting), id: \.day) { group in
                            Section(group.day) {
                                ForEach(group.revisions) { revision in
                                    NavigationLink(value: revision.id) {
                                        HStack(spacing: 12) {
                                            Image(systemName: RevisionText.symbol(revision)).foregroundStyle(PhoneStyle.Ink.secondary)
                                                .frame(width: 24).accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(RevisionText.title(revision, in: meeting)).foregroundStyle(PhoneStyle.Ink.title)
                                                if let detail = detail(revision, in: meeting) {
                                                    Text(detail).font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary).lineLimit(1)
                                                }
                                            }
                                            Spacer(minLength: 6)
                                            Text(revision.date.formatted(date: .omitted, time: .shortened))
                                                .font(.footnote.monospacedDigit()).foregroundStyle(PhoneStyle.Ink.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .navigationDestination(for: UUID.self) { id in
                        if let revision = meeting.revisions.first(where: { $0.id == id }) {
                            RevisionDetail(library: library, meetingID: meetingID, revision: revision)
                        }
                    }
                    #if DEBUG
                    .task {
                        // `--history-change "Summary written"` opens the newest change with that title, for screenshots.
                        guard let index = CommandLine.arguments.firstIndex(of: "--history-change"), CommandLine.arguments.indices.contains(index + 1),
                              let change = meeting.revisions.last(where: { RevisionText.title($0, in: meeting) == CommandLine.arguments[index + 1] })
                        else { return }
                        path = [change.id]
                    }
                    #endif
                } else {
                    EmptyPlace(title: "No Changes Yet", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func groups(_ meeting: Meeting) -> [(day: String, revisions: [MeetingRevision])] {
        var result: [(day: String, revisions: [MeetingRevision])] = []
        for revision in meeting.revisions.reversed() {
            let day = DateGroup.title(for: revision.date, now: Date(), calendar: .current)
            if result.last?.day == day { result[result.count - 1].revisions.append(revision) } else { result.append((day, [revision])) }
        }
        return result
    }

    /// The line under a change's title: what it's about, else what it says now; nothing when that
    /// only repeats the title ("Photo added", "added").
    private func detail(_ revision: MeetingRevision, in meeting: Meeting) -> String? {
        let title = RevisionText.title(revision, in: meeting)
        let subject = RevisionText.subject(revision, in: meeting)
        if subject != title { return subject }
        let text = RevisionText.readable(revision.newValue, field: revision.field).replacingOccurrences(of: "\n", with: " ")
        if text.isEmpty { return "Empty" }
        return title.localizedCaseInsensitiveContains(text) ? nil : text
    }
}

private struct RevisionDetail: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    let revision: MeetingRevision
    @Environment(\.colorScheme) private var scheme
    @State private var confirming = false
    @State private var restored = false

    var body: some View {
        if let meeting = library.meeting(meetingID) {
            ScrollView {
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s5) {
                    VStack(alignment: .leading, spacing: 4) {
                        // The title above says what kind of change it was; this says what it's about, when that's more.
                        let subject = RevisionText.subject(revision, in: meeting)
                        if subject != RevisionText.title(revision, in: meeting) {
                            Text(subject).font(PhoneStyle.Typeface.rowTitle).foregroundStyle(PhoneStyle.Ink.title)
                        }
                        Text(revision.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                    let diff = WordDiff.marked(old: RevisionText.styled(revision.oldValue, field: revision.field),
                                               new: RevisionText.styled(revision.newValue, field: revision.field), dark: scheme == .dark)
                    if RevisionText.hasBefore(revision) {
                        comparison("Before", diff.old)
                        comparison("After", diff.new)
                    } else {
                        comparison(nil, diff.new)
                    }
                    if restored {
                        Label("Restored", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(PhoneStyle.Ink.link)
                    }
                }
                .padding(PhoneStyle.Page.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .paperBackground()
            .navigationTitle(RevisionText.title(revision, in: meeting))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if RevisionRestore.canRestore(revision, in: meeting) {
                    // Not while a Mac is rewriting the conversation: the restore would be overwritten.
                    if !isLocked(meeting) {
                        Button { confirming = true } label: {
                            Text("Restore Previous Version").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(PhoneStyle.prominentFill)
                        .padding(.horizontal, PhoneStyle.Space.s4).padding(.bottom, PhoneStyle.Space.s2)
                    }
                }
            }
            .confirmationDialog("Restore the previous version?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore") {
                    library.restore(revision, in: meetingID)
                    withAnimation { restored = true }
                }
            } message: {
                Text("What’s there now stays in Version History.")
            }
        }
    }

    /// While a Mac is rewriting this conversation, a restore would be overwritten.
    private func isLocked(_ meeting: Meeting) -> Bool {
        if case .processing = ProcessingStatus(meeting) { return true }
        return false
    }

    private func comparison(_ title: String?, _ text: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: PhoneStyle.Space.s2) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(PhoneStyle.Ink.secondary).accessibilityAddTraits(.isHeader)
            }
            Group {
                if text.characters.isEmpty { Text("Empty").italic().foregroundStyle(PhoneStyle.Ink.meta) }
                else { Text(text).foregroundStyle(PhoneStyle.Ink.body) }
            }
            .font(.body)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Correct Passage: the words as heard, editable. The model's original stays in Version History.
struct PassageCorrectionSheet: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    let segmentID: UUID
    private let dismiss = SheetDismiss()
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            if let meeting = library.meeting(meetingID), let segment = meeting.unifiedTranscript.first(where: { $0.id == segmentID }) {
                VStack(alignment: .leading, spacing: PhoneStyle.Space.s3) {
                    HStack(spacing: 8) {
                        Text(meeting.speakerName(segment.speakerID) ?? "Unknown speaker")
                            .font(PhoneStyle.Typeface.speaker)
                            .foregroundStyle(PhoneStyle.speakerInk(meeting.speakerIndex(segment.speakerID)))
                        Text(TimeLabel.short(segment.start)).font(PhoneStyle.Typeface.time).foregroundStyle(PhoneStyle.Ink.meta)
                    }
                    TextEditor(text: $draft)
                        .font(.body)
                        .foregroundStyle(PhoneStyle.Ink.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PhoneStyle.accent, lineWidth: 1.5))
                        .focused($focused)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Corrected passage")
                    Spacer(minLength: 0)
                }
                .padding(PhoneStyle.Page.gutter)
                .paperBackground()
                .navigationTitle("Correct Passage")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty, text != segment.text { library.correctPassage(segment.id, text: text, in: meetingID) }
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { draft = segment.text; focused = true }
            } else {
                ContentUnavailableView("Passage Not Found", systemImage: "text.quote")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Which recordings heard a passage, each with what it heard and a way to play it.
struct HeardInSheet: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    let segmentID: UUID
    private let dismiss = SheetDismiss()
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    var body: some View {
        NavigationStack {
            if let meeting = library.meeting(meetingID), let segment = meeting.unifiedTranscript.first(where: { $0.id == segmentID }) {
                List {
                    Section {
                        ForEach(Array(segment.provenance.enumerated()), id: \.offset) { _, source in
                            let track = meeting.tracks.first { $0.id == source.trackID }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(track.map { SourceDescription.name($0, in: meeting) } ?? "Recording",
                                          systemImage: track.map(SourceDescription.symbol) ?? "waveform")
                                    Spacer()
                                    if let track {
                                        Button {
                                            session.player.play(.source(track, source.start), in: meeting, provider: provider)
                                            dismiss()
                                        } label: {
                                            Label(TimeLabel.short(source.start), systemImage: "play.fill").monospacedDigit()
                                        }
                                        .buttonStyle(.daybookLink)
                                        .font(.subheadline.weight(.medium))
                                    }
                                }
                                Text("“\(source.text)”").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .navigationTitle("Heard in \(segment.provenance.count) Recordings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            } else {
                ContentUnavailableView("Passage Not Found", systemImage: "text.quote")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The words behind a plain message: a Mac's own reason for a failure, or the system's error.
struct DetailsSheet: View {
    var title = "What Your Mac Said"
    let text: String
    private let dismiss = SheetDismiss()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PhoneStyle.Page.gutter)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// The system share sheet. Once it's done (shared, saved, or cancelled), the export files go.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let files = items.compactMap { $0 as? URL }
        controller.completionWithItemsHandler = { _, _, _, _ in ExportFiles.clear(files) }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension EnvironmentValues {
    /// Set while a reading sheet shows on the notebook's right page rather than presented: closes it.
    @Entry var closePageSheet: (() -> Void)? = nil
}

/// Closes a reading sheet however it shows: presented (dismiss), or on the notebook's right page.
struct SheetDismiss: DynamicProperty {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.closePageSheet) private var closePageSheet

    func callAsFunction() {
        if !isPresented, let closePageSheet { closePageSheet() } else { dismiss() }
    }
}

/// Presents whichever sheet the reading session asks for.
struct ReadingSheetContent: View {
    let sheet: ReadingSheet
    @ObservedObject var library: LibraryController

    var body: some View {
        switch sheet {
        case .importPhotos(let id): ImportPhotosSheet(library: library, meetingID: id)
        case .photo(let meeting, let photo): PhotoViewer(library: library, meetingID: meeting, photoID: photo)
        case .info(let id): ConversationInfo(library: library, meetingID: id)
        case .history(let id): VersionHistoryView(library: library, meetingID: id)
        case .share(let urls): ShareSheet(items: urls).presentationDetents([.medium, .large]).ignoresSafeArea()
        case .move(let ids): MoveSheet(library: library, ids: ids)
        case .tags(let ids): TagsSheet(library: library, ids: ids)
        case .correct(let meeting, let segment): PassageCorrectionSheet(library: library, meetingID: meeting, segmentID: segment)
        case .heardIn(let meeting, let segment): HeardInSheet(library: library, meetingID: meeting, segmentID: segment)
        case .details(let text): DetailsSheet(text: text)
        case .errorDetails(let text): DetailsSheet(title: "Details", text: text)
        }
    }
}
