import CoreTransferable
import DaybookCaptions
import DaybookKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import DaybookUI

/// The library list both apps draw: what a row says to VoiceOver, which actions each app's menus show, and how a
/// conversation travels when it's dragged, copied, or shared.
final class LibraryListTests: XCTestCase {
    private func ready() -> Meeting {
        var meeting = Meeting(title: "Weekly product sync")
        meeting.summary = MeetingSummary(kind: .general, overview: "The team kept the beta date.")
        meeting.tags = ["launch", "beta"]
        return meeting
    }

    func testBehaviorVoiceOverReadsTheRowsGistOrWhatsHappeningInItsPlace() {
        let meeting = ready()
        let label = ConversationRowView.spokenLabel(meeting, status: nil, timeLabel: "9:41 AM")
        XCTAssertEqual(label, "Weekly product sync, 9:41 AM, The team kept the beta date., Tags: launch, beta")
        let busy = ConversationRowStatus(kind: .processing, text: "Transcribing · 40%", fraction: 0.4)
        XCTAssertEqual(ConversationRowView.spokenLabel(meeting, status: busy, timeLabel: "9:41 AM"),
                       "Weekly product sync, 9:41 AM, Transcribing · 40%, Tags: launch, beta", "the words that took the gist's place")
        let playing = ConversationRowStatus(kind: .playing, text: nil)
        XCTAssertTrue(ConversationRowView.spokenLabel(meeting, status: playing, timeLabel: "9:41 AM").contains("Playing, The team kept the beta date."))
        XCTAssertEqual(ConversationRowView.title(Meeting(title: "  ")), "Untitled Conversation")
    }

    func testBehaviorAPausedRowShowsThePauseGlyphOnBothApps() {
        XCTAssertEqual(ConversationRowStatus.Kind.paused.symbol, "pause.circle")
        XCTAssertEqual(ConversationRowStatus.Kind.waitingForModels.symbol, "arrow.down.circle")
        XCTAssertEqual(ConversationRowStatus.Kind.justFinished.symbol, "checkmark.circle.fill")
    }

    func testBehaviorTheMacDimsWhatDoesntApplyAndTheIPhoneLeavesItOut() {
        let meeting = Meeting(title: "Notes only")
        let groups = ConversationActions.actions(for: meeting, context: .init(platform: .iPhone))
        let shown = ConversationActionMenuItems.shown(groups, on: .iPhone).flatMap(\.actions)
        XCTAssertFalse(shown.contains { $0.id == .copySummary }, "no summary yet: left out")
        XCTAssertFalse(shown.contains { $0.id == .reprocess }, "no recording yet: left out")
        XCTAssertTrue(shown.contains { $0.id == .moveToTrash })
        let mac = ConversationActions.actions(for: meeting, context: .init(platform: .mac))
        XCTAssertEqual(ConversationActionMenuItems.shown(mac, on: .mac), mac, "a Mac's menu dims instead")
        XCTAssertEqual(ConversationActionMenuItems.action(.copySummary, in: mac)?.isAvailable, false)
    }

    func testBehaviorASelectionOffersSummarizeFilingTagsAndTheTrashInOneOrderWithShortWordsForTheBar() {
        var transcribed = Meeting(title: "A")
        transcribed.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Hello")]
        let other = Meeting(title: "B")
        let groups = ConversationActions.batch([transcribed.id, other.id], in: [transcribed, other], context: .init(platform: .iPhone))
        let actions = ConversationActionMenuItems.shown(groups, on: .iPhone).flatMap(\.actions)
        XCTAssertEqual(actions.map(ConversationActionMenuItems.shortTitle), ["Summarize", "Move", "Tags", "Personal", "Trash"])
    }

    func testBehaviorAConversationTravelsAsItsIDInsideDaybookAndAsMarkdownOrWordsOutside() throws {
        let meeting = ready()
        let transfer = ConversationTransfer(meeting)
        let data = try JSONEncoder().encode(transfer)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "title"], "inside Daybook only the conversation's ID and title travel")
        let decoded = try JSONDecoder().decode(ConversationTransfer.self, from: data)
        XCTAssertEqual(decoded.id, meeting.id)
        XCTAssertEqual(transfer.text, "Weekly product sync\n\nThe team kept the beta date.")
        XCTAssertEqual(UTType.daybookConversation.identifier, "local.daybook.conversation")

        let url = try transfer.writeMarkdown()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, MeetingExport.fileName(for: meeting) + ".md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), MeetingExport.markdown(meeting))
    }

    func testBehaviorCaptionSearchFindsSavedCaptionsUntilATranscriptReplacesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookCaptionSearch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = LibraryCaptionSearch.directory(libraryRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let captioned = Meeting(title: "Onboarding design review")
        let replaced = Meeting(title: "Replaced")
        let found = Meeting(title: "Found by text")
        func save(_ meeting: Meeting, _ text: String) throws {
            let captions = LiveCaptions(meetingID: meeting.id, trackID: nil, localeIdentifier: "en_US",
                                        segments: [LiveCaptionSegment(start: 12, end: 14, text: text, isTentative: false)])
            try JSONEncoder().encode(captions).write(to: folder.appendingPathComponent("\(meeting.id.uuidString).json"))
        }
        try save(captioned, "We walked through the onboarding checklist.")
        try save(found, "The checklist again.")
        var later = replaced
        later.transcripts = [TrackTranscript(trackID: UUID(), segments: [], modelID: "m", createdAt: Date().addingTimeInterval(60))]
        try save(later, "A checklist the transcript has.")

        let hits = await LibraryCaptionSearch.hits(in: [captioned, later, found], query: "checklist", excluding: [found.id], libraryRoot: root)
        XCTAssertEqual(hits.map(\.meeting.id), [captioned.id], "not the one the text search found, nor one its transcript replaced")
        XCTAssertEqual(hits.first?.segment.start, 12)
        let none = await LibraryCaptionSearch.hits(in: [captioned], query: "  ", excluding: [], libraryRoot: root)
        XCTAssertTrue(none.isEmpty)
    }
}
