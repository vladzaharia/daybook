import CoreGraphics
import DaybookDesign
import DaybookKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import DaybookUI

/// The transcript page, its sheets, and the photo views both apps share: their words, their rules, and the edits they
/// make, each undoable.
@MainActor
final class TranscriptScreensTests: XCTestCase {
    private let track = UUID()

    private func library() async throws -> LibraryController {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookUITranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryController(rootURL: folder, sync: nil)
        try await library.load()
        return library
    }

    private func recorded(_ title: String = "Interview with Sam") -> Meeting {
        Meeting(title: title, tracks: [RecordingTrack(id: track, source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a")])
    }

    // MARK: Before there's a transcript

    func testBehaviorTheEmptyTranscriptLeavesAFailuresReasonToTheBoxBesideIt() {
        let failure = ProcessingStatus.Failure(reason: "Models aren't installed", hadTranscripts: false,
                                               device: .init(id: "studio", name: "Studio Mac"), kind: .modelsMissing)
        let words = EmptyTranscript<EmptyView>.words(meeting: recorded(), status: .failed(failure), device: .iPhone(id: "phone"),
                                                     showsReason: false)
        XCTAssertEqual(words.title, "No transcript")
        XCTAssertNil(words.message, "on two pages the summary's box says why, with Try Again")
    }

    func testBehaviorTheEmptyTranscriptNamesTheDeviceThatFailedInTheSharedWords() {
        let meeting = recorded()
        let iPhone = DeviceWords.iPhone(id: "phone")
        func message(_ failure: ProcessingStatus.Failure) -> String? {
            EmptyTranscript<EmptyView>.words(meeting: meeting, status: .failed(failure), device: iPhone, showsReason: true).message
        }
        let here = message(.init(reason: "", hadTranscripts: false, device: .init(id: "phone", name: "Alex’s iPhone"), kind: .other))
        XCTAssertEqual(here, "Something went wrong on this iPhone. The recording is saved.", "this iPhone's own work isn't blamed on a Mac")
        let mac = message(.init(reason: "", hadTranscripts: false, device: .init(id: "studio", name: "Studio Mac"), kind: .modelsMissing))
        XCTAssertEqual(mac, "The models it needs aren’t on Studio Mac yet. The recording is saved.", "the words the summary's box uses")
        XCTAssertEqual(message(.init(reason: "No speech", hadTranscripts: false, kind: .noSpeech)),
                       "No speech in this recording. The recording is saved.")

        XCTAssertEqual(EmptyTranscript<EmptyView>.words(meeting: meeting, status: .recorded, device: iPhone, showsReason: true).title,
                       "Not transcribed yet")
        XCTAssertEqual(EmptyTranscript<EmptyView>.words(meeting: Meeting(title: "Notes"), status: .done, device: iPhone, showsReason: true).title,
                       "No recording yet")
    }

    // MARK: Notices and sheets

    func testBehaviorNoticesNameTheRecordingAsAudioDoesAndOfferTheirFix() {
        var meeting = recorded()
        meeting.tracks += [
            RecordingTrack(source: .imported, relativePath: "Originals/standup.m4a", fileName: "standup.m4a"),
            RecordingTrack(source: .microphone, relativePath: "Processed/a.m4a", fileName: "a.m4a", derivedFrom: track,
                           processing: RecordingTrack.echoCancelledProcessing),
        ]
        let names = meeting.tracks.map { RecordingWords.name($0, in: meeting) }
        XCTAssertEqual(names.map { TranscriptNoticeWords.unaligned($0) }, [
            "Couldn’t line up “Microphone, original” with the other recordings",
            "Couldn’t line up “standup.m4a” with the other recordings",
            "Couldn’t line up “Microphone, echo removed” with the other recordings",
        ], "every name Audio gives reads in it, a file's and one with a comma too")
        XCTAssertEqual(TranscriptNoticeWords.unaligned("Alex’s iPhone"), "Couldn’t line up “Alex’s iPhone” with the other recordings")
        XCTAssertEqual(TranscriptNoticeWords.unaligned(nil), "Couldn’t line up a recording with the others", "its recording gone")
        XCTAssertEqual(TranscriptNoticeWords.corrections(1), "An earlier correction needs a look")
        XCTAssertEqual(TranscriptNoticeWords.corrections(3), "3 earlier corrections need a look")
        XCTAssertEqual(TranscriptNoticeWords.review, "Review…", "the same action on both apps, never \"Review it on your Mac\"")
        XCTAssertEqual(TranscriptNoticeWords.adjustTiming, "Adjust Timing…")
    }

    func testBehaviorAdjustTimingReadsTimesAndRefusesHalfTypedOnes() {
        XCTAssertEqual(TimeField.parse("42"), 42)
        XCTAssertEqual(TimeField.parse(" 0:42 "), 42)
        XCTAssertEqual(TimeField.parse("1:02:03"), 3723)
        XCTAssertEqual(TimeField.parse("−0:12"), -12, "a recording that began before the others")
        XCTAssertNil(TimeField.parse("1:"))
        XCTAssertNil(TimeField.parse("1::2"))
        XCTAssertNil(TimeField.parse("soon"))
        XCTAssertNil(TimeField.parse(""))
    }

    func testBehaviorAdjustTimingPicksTheRecordingThatCouldntBeLinedUp() {
        var meeting = recorded()
        let second = UUID(), third = UUID()
        meeting.tracks += [RecordingTrack(id: second, source: .soundcore, relativePath: "b", fileName: "b"),
                           RecordingTrack(id: third, source: .soundcore, relativePath: "c", fileName: "c")]
        XCTAssertEqual(AdjustTimingSheet.defaultTrack(in: meeting), second)
        meeting.alignmentReports = [TrackAlignment(trackID: third, method: .unaligned)]
        XCTAssertEqual(AdjustTimingSheet.defaultTrack(in: meeting), third)
        // A recording taken out of the conversation isn't one to line up.
        meeting.alignmentReports = [TrackAlignment(trackID: second, method: .unaligned)]
        meeting.tracks[1].removal = RecordingRemoval(removedAt: Date())
        XCTAssertEqual(AdjustTimingSheet.defaultTrack(in: meeting), third)
    }

    func testBehaviorCorrectPassageAsksBeforeLosingWhatWasTyped() {
        XCTAssertFalse(CorrectPassageSheet.hasChanges(draft: nil, original: "The sink fix"), "nothing typed yet")
        XCTAssertFalse(CorrectPassageSheet.hasChanges(draft: "The sink fix ", original: "The sink fix"))
        XCTAssertTrue(CorrectPassageSheet.hasChanges(draft: "The sync fix", original: "The sink fix"))
    }

    func testBehaviorReviewChoosesAPassageForTheCorrectionItShows() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Weekly")
        let passages = (0..<6).map { TranscriptSegment(trackID: track, start: Double($0 * 5), end: Double($0 * 5 + 4), text: "Passage \($0)") }
        let issues = ["The sync fix", "Ship on Friday", "Dana owns it"].enumerated().map { n, text in
            CorrectionTransferIssue(originalSegment: TranscriptSegment(trackID: track, start: Double(n * 10), end: Double(n * 10 + 4), text: text),
                                    candidateSegmentIDs: [passages[n * 2].id, passages[n * 2 + 1].id], reason: "Transcribed again")
        }
        library.update(id) { $0.unifiedTranscript = passages; $0.correctionTransferIssues = issues }
        func pending() -> [CorrectionTransferIssue] { library.meeting(id)?.correctionTransferIssues ?? [] }
        func shown(_ place: ReviewCorrectionsPlace) -> CorrectionTransferIssue {
            pending()[ReviewCorrectionsPlace.position(place.index, count: pending().count)]
        }

        var place = ReviewCorrectionsPlace.showing(0, of: pending(), in: library.meeting(id))
        XCTAssertEqual(shown(place).id, issues[0].id)
        XCTAssertEqual(place.target(for: shown(place)), passages[0].id, "opened, the likeliest passage is chosen")

        place = place.skipping(pending(), in: library.meeting(id))
        XCTAssertEqual(shown(place).id, issues[1].id)
        XCTAssertEqual(place.target(for: shown(place)), passages[2].id, "Skip chooses for the correction it shows")
        XCTAssertNil(place.target(for: issues[0]), "a choice belongs to the correction it was made for")

        // Apply on the second: the third moves into its place, with a passage chosen from its own.
        library.resolveCorrectionTransfer(issues[1].id, targetSegmentID: place.target(for: shown(place)), in: id)
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript[2].text, "Ship on Friday")
        place = .showing(place.index, of: pending(), in: library.meeting(id))
        let next = shown(place)
        XCTAssertEqual(next.id, issues[2].id)
        let target = try XCTUnwrap(place.target(for: next), "Apply stays ready")
        XCTAssertTrue(ReviewCorrectionsSheet.candidates(next, in: library.meeting(id)).contains { $0.id == target })
        XCTAssertEqual(target, passages[4].id, "never the passage chosen for the first correction")

        // Keep on the last: the one left shows, first again.
        library.resolveCorrectionTransfer(next.id, targetSegmentID: nil, in: id)
        place = .showing(place.index, of: pending(), in: library.meeting(id))
        XCTAssertEqual(shown(place).id, issues[0].id)
        XCTAssertEqual(place.target(for: shown(place)), passages[0].id)
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.map(\.text),
                       ["Passage 0", "Passage 1", "Ship on Friday", "Passage 3", "Passage 4", "Passage 5"])
    }

    #if os(macOS)
    /// Review reads its own height to choose whether to scroll, so on the Mac its sheet keeps one size: one that followed
    /// a long correction never settled. A correction too long for it scrolls inside.
    func testBehaviorReviewKeepsOneSizeOnTheMacHoweverLongTheCorrection() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Weekly")
        let passages = (0..<4).map { TranscriptSegment(trackID: track, start: Double($0 * 5), end: Double($0 * 5 + 4), text: "Passage \($0)") }
        let long = String(repeating: "We spent the whole next week chasing a duplicate that only showed up on two Macs. ", count: 20)
        for text in ["Ship on Friday", long] {
            let issue = CorrectionTransferIssue(originalSegment: TranscriptSegment(trackID: track, start: 0, end: 4, text: text),
                                                candidateSegmentIDs: [passages[1].id], reason: "Transcribed again")
            library.update(id) { $0.unifiedTranscript = passages; $0.correctionTransferIssues = [issue] }
            let sheet = NSHostingView(rootView: ReviewCorrectionsSheet(library: library, meetingID: id))
            XCTAssertEqual(sheet.fittingSize, CGSize(width: 560, height: 540), "\(text.count) characters")
        }
    }
    #endif

    func testBehaviorAPageSheetClosesThroughOneComparableAction() {
        var closed = 0
        let first = ClosePageSheetAction { closed += 1 }
        let again = ClosePageSheetAction { closed += 10 }
        XCTAssertEqual(first, again, "the page making its closure again doesn't redraw what reads it")
        first()
        XCTAssertEqual(closed, 1)
    }

    func testBehaviorOriginalTranscriptReadsTheRecordingsLatestRun() {
        var meeting = recorded()
        meeting.transcripts = [
            TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 1, end: 2, text: "Old")], modelID: "a",
                            createdAt: Date(timeIntervalSince1970: 10)),
            TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 62, end: 64, text: "New")], modelID: "b",
                            createdAt: Date(timeIntervalSince1970: 20)),
        ]
        let run = OriginalTranscriptSheet.run(of: track, in: meeting)
        XCTAssertEqual(run?.modelID, "b")
        XCTAssertEqual(OriginalTranscriptSheet.text(run), "[1:02] New")
    }

    // MARK: The page

    func testBehaviorRotorsListBookmarksNotesAndEachSpeakersTurns() {
        var meeting = recorded("Weekly")
        meeting.speakers = [Speaker(id: "S0", name: "Maya"), Speaker(id: "S1", name: "Daniel")]
        meeting.unifiedTranscript = [
            TranscriptSegment(trackID: track, start: 0, end: 4, text: "Let's start.", speakerID: "S0"),
            TranscriptSegment(trackID: track, start: 5, end: 9, text: "Sync is the gate.", speakerID: "S1"),
            TranscriptSegment(trackID: track, start: 10, end: 14, text: "Then we hold the date.", speakerID: "S0"),
        ]
        meeting.timedNotes = [TimedNote(time: 6, text: "Gate on sync")]
        meeting.highlights = [Highlight(trackID: track, time: 5.5, text: "The gate")]
        meeting.alignmentReports = [TrackAlignment(trackID: track, method: .reference)]
        let layout = TranscriptLayout(meeting)
        let rotors = TranscriptRotorEntries(rows: TranscriptRow.rows(from: layout.blocks), marks: layout.marks, meeting: meeting)
        XCTAssertEqual(rotors.bookmarks.map(\.label), ["0:05, The gate"])
        XCTAssertEqual(rotors.bookmarks.first?.id, meeting.unifiedTranscript[1].id.uuidString)
        XCTAssertEqual(rotors.notes.map(\.label), ["0:06, Gate on sync"])
        XCTAssertEqual(rotors.speakers.map(\.name), ["Maya", "Daniel"])
        XCTAssertEqual(rotors.speakers.first?.turns.count, 2, "one entry per turn, in the order they're read")
    }

    func testBehaviorFindInConversationStartsOverForAnotherConversation() {
        var meeting = recorded("Weekly")
        meeting.unifiedTranscript = [
            TranscriptSegment(trackID: track, start: 0, end: 4, text: "The release holds."),
            TranscriptSegment(trackID: track, start: 5, end: 9, text: "Release notes are drafted."),
        ]
        let find = ConversationFind()
        find.use(TranscriptRow.rows(in: meeting), in: meeting.id)
        find.show()
        find.query = "release"
        XCTAssertEqual(find.label, "1 of 2")
        XCTAssertEqual(find.highlight, "release", "marked while the bar shows")
        let steps = find.stepToken
        find.next()
        XCTAssertEqual(find.label, "2 of 2")
        XCTAssertEqual(find.stepToken, steps + 1, "each step moves the page")
        find.close()
        XCTAssertEqual(find.highlight, "", "closed, nothing is marked")
        find.show(in: meeting.id)
        XCTAssertEqual(find.query, "release", "what was typed stays for next time")

        let other = recorded("Other")
        find.use(TranscriptRow.rows(in: other), in: other.id)
        XCTAssertFalse(find.isShown)
        XCTAssertEqual(find.query, "")
        XCTAssertNil(find.label)
    }

    func testBehaviorCorrectionsAndRenamesAreUndoneByUndo() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Weekly")
        let segment = TranscriptSegment(trackID: track, start: 0, end: 2, text: "The sink fix", speakerID: "S0")
        library.update(id) { $0.unifiedTranscript = [segment]; $0.speakers = [Speaker(id: "S0", name: "Speaker 1")] }
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        XCTAssertTrue(TranscriptEdits.correct(segment.id, text: "  The sync fix ", in: id, library: library, undoManager: undo))
        undo.endUndoGrouping()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "The sync fix")
        XCTAssertEqual(undo.undoActionName, "Correct Passage")
        XCTAssertFalse(TranscriptEdits.correct(segment.id, text: "   ", in: id, library: library, undoManager: undo), "an empty passage isn't saved")

        undo.beginUndoGrouping()
        XCTAssertTrue(TranscriptEdits.rename("S0", to: "Maya", in: id, library: library, undoManager: undo))
        undo.endUndoGrouping()
        XCTAssertEqual(library.meeting(id)?.speakerName("S0"), "Maya")
        XCTAssertEqual(undo.undoActionName, "Rename Speaker")

        undo.undo()
        XCTAssertEqual(library.meeting(id)?.speakerName("S0"), "Speaker 1")
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.unifiedTranscript.first?.text, "The sink fix")
        XCTAssertGreaterThanOrEqual(library.meeting(id)?.revisions.count ?? 0, 4, "Version History keeps each change and its undo")
    }

    // MARK: Photos

    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testBehaviorADeletedPhotoComesBackWithUndoAndStaysInVersionHistory() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Whiteboard")
        await library.acquireLock()
        let photo = try await library.addPhoto(data: try png(), to: id)
        library.releaseLock()
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        PhotoActions.delete(photo, meetingID: id, library: library, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertTrue(library.meeting(id)?.visiblePhotos.isEmpty == true)
        XCTAssertEqual(undo.undoActionName, "Delete Photo")
        undo.undo()
        XCTAssertEqual(library.meeting(id)?.visiblePhotos.map(\.id), [photo.id])
        undo.redo()
        XCTAssertTrue(library.meeting(id)?.visiblePhotos.isEmpty == true, "redo deletes it again")
        XCTAssertTrue(library.meeting(id)?.revisions.contains { $0.field == "photo:\(photo.id.uuidString)" } == true)
        XCTAssertEqual(PhotoActions.deleteTitle, "Delete this photo?")
        XCTAssertEqual(PhotoActions.deleteMessage, "It stays in Version History.")
    }

    func testBehaviorRemovingAPhotoFromTheSummaryTakesItOffEverySection() async throws {
        let library = try await library()
        let id = library.newMeeting(title: "Whiteboard")
        await library.acquireLock()
        let photo = try await library.addPhoto(data: try png(), to: id)
        library.releaseLock()
        library.update(id) {
            $0.summary = MeetingSummary(overview: "Plans", sections: [SummarySection(heading: "Board", body: "- Drawn", photoIDs: [photo.id])],
                                        modelID: "m")
        }

        PhotoActions.setUsedInSummary(false, photo: photo, meetingID: id, library: library)
        let removed = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(removed.photo(photo.id)?.hiddenFromSummary, true)
        XCTAssertTrue(removed.summary?.sections.allSatisfy { ($0.photoIDs ?? []).isEmpty } == true)
        XCTAssertEqual(removed.visiblePhotos.map(\.id), [photo.id], "the photo stays in the strip and the transcript")

        PhotoActions.setUsedInSummary(true, photo: photo, meetingID: id, library: library)
        XCTAssertNotEqual(library.meeting(id)?.photo(photo.id)?.hiddenFromSummary, true)
    }

    func testBehaviorTheViewerMovesToTheNextPhotoOrTheOneBefore() {
        let photos = (0..<3).map { index in
            MeetingPhoto(relativePath: "p\(index)", fileName: "p\(index).png", sha256: "", capturedAt: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(PhotoViewerSteps.after(deleting: photos[1].id, in: photos), photos[2].id)
        XCTAssertEqual(PhotoViewerSteps.after(deleting: photos[2].id, in: photos), photos[1].id)
        XCTAssertNil(PhotoViewerSteps.after(deleting: photos[0].id, in: [photos[0]]), "the only photo: the viewer closes")
    }

    func testBehaviorAThumbnailIsDecodedAtItsSizeAndKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookUIPhoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.png")
        try png().write(to: url)
        let cache = PhotoImageCache()
        let image = await cache.image(url, maxPixels: 20)
        XCTAssertEqual(image.map { max($0.width, $0.height) }, 20)
        XCTAssertNotNil(cache.cached(url, maxPixels: 20), "kept for the next time the tile shows")
        let missing = await cache.image(folder.appendingPathComponent("missing.png"), maxPixels: 20)
        XCTAssertNil(missing, "no original, no image")
    }
}
