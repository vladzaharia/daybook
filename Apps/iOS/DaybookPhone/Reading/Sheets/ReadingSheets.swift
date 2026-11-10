import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

/// Closes a reading sheet however it shows: presented, or on the notebook's right page (DaybookUI's, which the shared
/// sheets use too).
typealias SheetDismiss = DaybookUI.SheetDismiss

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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.tint(PhoneStyle.Ink.title) } }
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

/// Presents whichever sheet the reading session asks for. The conversation's tools (Version History, Correct Passage,
/// Review Earlier Corrections, Adjust Timing, Original Transcript, the photo viewer) are DaybookUI's, the same sheets
/// the Mac shows.
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
        case .history(let id):
            // Not while a Mac is rewriting the conversation: the restore would be overwritten.
            VersionHistoryScreen(library: library, meetingID: id) { meeting in
                if case .processing = ProcessingStatus.phone(meeting) { return true }
                return false
            }
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
