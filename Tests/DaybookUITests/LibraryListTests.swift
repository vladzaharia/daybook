import CoreTransferable
import DaybookCaptions
import DaybookDesign
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

    /// VM-14: one glyph language. Waiting states are secondary symbols in one slot, audio not transcribed yet among
    /// them as a waveform (never a dot that reads as "unread"); only work running draws the gradient line.
    func testBehaviorEveryWaitingGlyphIsASymbolAndOnlyWorkDrawsTheLine() {
        XCTAssertEqual(ConversationRowStatus.Kind.notTranscribed.symbol, "waveform")
        XCTAssertEqual(ConversationRowStatus.Kind.waiting.symbol, "clock")
        XCTAssertNil(ConversationRowStatus.Kind.processing.symbol, "the gradient line")
        let symbols: [ConversationRowStatus.Kind] = [.recording, .waiting, .waitingForModels, .paused, .failed, .notTranscribed, .playing, .justFinished]
        XCTAssertTrue(symbols.allSatisfy { $0.symbol != nil })
        XCTAssertEqual(RowGlyph.slot, 16)
    }

    /// VM-13: in a window every row is two lines; its tags end the date's line, by name while they fit beside the
    /// gist's start, with a count for the rest, else the count alone.
    func testBehaviorAWindowRowEndsItsDateLineWithItsTagsOrACount() {
        XCTAssertEqual(RowTags.arrangements(["launch", "beta"]), [["launch", "beta"], ["launch", "+1"], ["+2"]])
        XCTAssertEqual(RowTags.arrangements(["launch"]), [["launch"], ["+1"]])
        XCTAssertEqual(RowTags.arrangements(["a", "b", "c", "d"]), [["a", "b", "c", "+1"], ["a", "b", "+2"], ["a", "+3"], ["+4"]],
                       "three by name at most")
        XCTAssertEqual(RowTags.arrangements([]), [])
        XCTAssertTrue(ConversationRowView.spokenLabel(ready(), status: nil, timeLabel: "9:41 AM").hasSuffix("Tags: launch, beta"),
                      "VoiceOver reads every tag, whatever fits")
    }

    /// VM-15: a window's gist takes one line, two once its list column is 360 pt wide; a panel's one, the iPhone's two
    /// (three at accessibility sizes).
    func testBehaviorAWideListColumnGivesTheGistTwoLinesInAWindowOnly() {
        XCTAssertEqual(ConversationRowView.twoLineGistWidth, 360)
        XCTAssertEqual(ConversationRowView.previewLines(.window, accessibilitySize: false, wideList: false), 1)
        XCTAssertEqual(ConversationRowView.previewLines(.window, accessibilitySize: false, wideList: true), 2)
        XCTAssertEqual(ConversationRowView.previewLines(.panel, accessibilitySize: false, wideList: true), 1)
        XCTAssertEqual(ConversationRowView.previewLines(.touch, accessibilitySize: false, wideList: false), 2)
        XCTAssertEqual(ConversationRowView.previewLines(.touch, accessibilitySize: true, wideList: true), 3)
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

    func testBehaviorShareSendsTheMarkdownOrTheWordsNeverTheInAppType() async throws {
        guard #available(macOS 15.2, iOS 18.2, *) else { throw XCTSkip("Content types are listed from macOS 15.2") }
        let meeting = ready()
        let dragged = ConversationTransfer(meeting).exportedContentTypes()
        XCTAssertEqual(dragged.first?.identifier, UTType.daybookConversation.identifier, "inside Daybook a drag or ⌘C leads with the conversation")

        let shared = ConversationShareItem(meeting)
        // Exporting writes the Markdown into a folder of its own under "Daybook Drag"; remove the ones this test made.
        let drags = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook Drag", isDirectory: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: drags.path)) ?? [])
        defer {
            for name in Set((try? FileManager.default.contentsOfDirectory(atPath: drags.path)) ?? []).subtracting(before) {
                try? FileManager.default.removeItem(at: drags.appendingPathComponent(name))
            }
        }
        let types = shared.exportedContentTypes()
        XCTAssertFalse(types.contains { $0.identifier == UTType.daybookConversation.identifier },
                       "AirDrop or Mail could pick it, and no one could read it")
        XCTAssertEqual(types.first, UTType.daybookMarkdown, "the Markdown file first")
        XCTAssertTrue(types.contains { $0.conforms(to: .plainText) && $0 != UTType.daybookMarkdown }, "then the words")
        let markdown = try await shared.exported(as: UTType.daybookMarkdown)
        XCTAssertEqual(String(decoding: markdown, as: UTF8.self), MeetingExport.markdown(meeting))
        let text = String(decoding: try await shared.exported(as: .utf8PlainText), as: UTF8.self)
        XCTAssertTrue(text.contains("Weekly product sync") && text.contains("The team kept the beta date."), "words anyone can read: \(text)")
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
