import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

/// Closes a reading sheet however it shows: presented, or on the notebook's right page (DaybookUI's, which the shared
/// sheets use too).
typealias SheetDismiss = DaybookUI.SheetDismiss

/// Version History: every change to the notes, the transcript, speaker names, and the summary,
/// newest first, each with what it was before and after, and Restore.
struct VersionHistoryView: View {
    let library: LibraryController
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
    let library: LibraryController
    let meetingID: UUID
    let revision: MeetingRevision
    @State private var confirming = false
    @State private var restored = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    // Drawn as the page draws it: the page's bullets, the changed words marked (shared with the Mac).
                    RevisionComparison(revision: revision)
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
                    withAnimation(PhoneStyle.Motion.resolved(PhoneStyle.Motion.fade, reduceMotion: reduceMotion)) { restored = true }
                }
            } message: {
                Text("What’s there now stays in Version History.")
            }
        }
    }

    /// While a Mac is rewriting this conversation, a restore would be overwritten.
    private func isLocked(_ meeting: Meeting) -> Bool {
        if case .processing = ProcessingStatus.phone(meeting) { return true }
        return false
    }
}

/// Which recordings heard a passage, as a sheet of its own (`--sheet heard`): the transcript shows the same thing as a
/// popover at the passage, which becomes a sheet in the hand.
private struct HeardInSheet: View {
    let library: LibraryController
    let meetingID: UUID
    let segmentID: UUID
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    var body: some View {
        if let meeting = library.meeting(meetingID), let segment = meeting.unifiedTranscript.first(where: { $0.id == segmentID }) {
            HeardInRecordings(meeting: meeting, segment: segment, recordingName: { RecordingWords.name($0, in: meeting) }) { target in
                session.player.play(target, in: meeting, provider: provider)
            }
        } else {
            ContentUnavailableView("Passage Not Found", systemImage: "text.quote")
        }
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

/// Presents whichever sheet the reading session asks for. The conversation's tools (Correct Passage, Review Earlier
/// Corrections, Adjust Timing, Original Transcript, the photo viewer) are DaybookUI's, the same sheets the Mac shows.
struct ReadingSheetContent: View {
    let sheet: ReadingSheet
    let library: LibraryController
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    var body: some View {
        content.modifier(PhonePhotoServices(library: library))
    }

    @ViewBuilder private var content: some View {
        switch sheet {
        case .importPhotos(let id): ImportPhotosSheet(library: library, meetingID: id)
        case .photo(let meeting, let photo):
            PhotoViewer(meetingID: meeting, photoID: photo, services: .phone(library: library, session: session, provider: provider))
        case .info(let id): ConversationInfo(library: library, meetingID: id)
        case .history(let id): VersionHistoryView(library: library, meetingID: id)
        case .share(let urls): ShareSheet(items: urls).presentationDetents([.medium, .large]).ignoresSafeArea()
        case .move(let ids): MoveSheet(library: library, ids: ids)
        case .tags(let ids): TagsSheet(library: library, ids: ids)
        case .correct(let meeting, let segment): CorrectPassageSheet(library: library, meetingID: meeting, segmentID: segment)
        case .heardIn(let meeting, let segment): HeardInSheet(library: library, meetingID: meeting, segmentID: segment)
        case .reviewCorrections(let meeting): ReviewCorrectionsSheet(library: library, meetingID: meeting)
        case .adjustTiming(let meeting, let track):
            AdjustTimingSheet(library: library, meetingID: meeting, trackID: track) { target in
                if let value = library.meeting(meeting) { session.player.play(target, in: value, provider: provider) }
            }
        case .originalTranscript(let meeting, let track): OriginalTranscriptSheet(library: library, meetingID: meeting, trackID: track)
        case .details(let text): DetailsSheet(text: text)
        case .errorDetails(let text): DetailsSheet(title: "Details", text: text)
        }
    }
}
