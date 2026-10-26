import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The library both apps share, on a temporary library: every edit saves, keeps its Version History,
/// and survives reopening; recordings keep their provenance; requests save like edits.
@MainActor
final class LibraryControllerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookKit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        XCTAssertTrue(library.isLoaded)
        return library
    }

    /// A small file; the store copies and hashes bytes without decoding them.
    private func file(_ name: String, _ contents: String) throws -> URL {
        let folder = root.appendingPathComponent("Incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testEditsSaveWithTheirHistoryAndSurviveReopening() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Untitled")
        library.rename(id, to: "Roadmap review")
        library.setTags(id, text: "planning, Q3, planning , q3,  ")
        library.setPlacement([id], .work)
        let folder = library.createFolder(named: "  Product  ", moving: [id])
        library.update(id) {
            $0.speakers = [Speaker(id: "s1", name: "Speaker 1")]
            $0.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 2, text: "The sink fix")]
            $0.summary = MeetingSummary(overview: "Plans", actionItems: [ActionItem(text: "Ship it")])
        }
        let segment = try XCTUnwrap(library.meeting(id)?.unifiedTranscript.first?.id)
        let step = try XCTUnwrap(library.meeting(id)?.summary?.actionItems.first?.id)
        library.renameSpeaker("s1", to: "Priya", in: id)
        library.correctPassage(segment, text: "The sync fix", in: id)
        library.setNextStep(step, completed: true, in: id)
        library.editNotes(id, text: "Beta date")
        await library.flush()

        var meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.tags, ["planning", "Q3"], "Trimmed, without duplicates that differ only in case")
        XCTAssertEqual(meeting.placement, .work)
        XCTAssertEqual(meeting.folderID, folder)
        XCTAssertEqual(library.folders.map(\.name), ["Product"])
        XCTAssertEqual(meeting.summary?.actionItems.first?.completed, true)
        XCTAssertEqual(meeting.revisions.map { $0.field.split(separator: ":").first.map(String.init) }, ["speaker", "segment", "notes"])

        // Version History › Restore puts the passage back and records what it replaced.
        let correction = try XCTUnwrap(meeting.revisions.first { $0.field.hasPrefix("segment") })
        library.restore(correction, in: id)
        await library.flush()
        meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.unifiedTranscript.first?.text, "The sink fix")
        XCTAssertEqual(meeting.revisions.last?.oldValue, "The sync fix")

        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(id), meeting)
        XCTAssertEqual(reopened.folders.map(\.id), [folder])

        reopened.removeFolder(folder)
        await reopened.flush()
        XCTAssertNil(reopened.meeting(id)?.folderID, "Its conversations stay, outside any folder")
        XCTAssertTrue(reopened.folders.isEmpty)
    }

    func testDurableFlushReportsAFailedSaveAndSucceedsAfterStorageRecovers() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Capture")
        try await library.flushDurably()
        let folder = root.appendingPathComponent("Meetings/\(id.uuidString)")
        let primary = folder.appendingPathComponent("meeting.json")
        let held = folder.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: primary, to: held)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        library.update(id) { $0.notes = "Keep this recovery note" }
        do { try await library.flushDurably(); XCTFail("Cleanup must not be authorized after a failed save") }
        catch {
            XCTAssertEqual(library.errorMessage, "Changes to “Capture” couldn’t be saved. Daybook tries again with your next change.")
            XCTAssertNotNil(library.errorDetails, "the system's words, kept for Details")
        }
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.moveItem(at: held, to: primary)
        library.rename(id, to: "Recovered capture")
        try await library.flushDurably()
        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(id)?.notes, "Keep this recovery note")
    }

    func testChoosingATemplateSaysWhetherItChanged() async throws {
        let library = try await open()
        let id = library.newMeeting()
        XCTAssertEqual(library.templateSelection(for: id), "auto")
        XCTAssertFalse(library.chooseTemplate("auto", for: id))
        XCTAssertTrue(library.chooseTemplate("scrum", for: id))
        XCTAssertEqual(library.meeting(id)?.templateID, "scrum")
        XCTAssertEqual(library.meeting(id)?.kind, .scrum)
        XCTAssertEqual(library.templateSelection(for: id), "scrum")
        XCTAssertEqual(library.resolvedTemplate(for: try XCTUnwrap(library.meeting(id)))?.id, "scrum")

        let custom = SummaryTemplate(name: "Board update", instructions: "Numbers first.")
        library.saveTemplate(custom)
        XCTAssertTrue(library.templates.contains { $0.id == custom.id })
        library.removeTemplate(custom.id)
        XCTAssertFalse(library.templates.contains { $0.id == custom.id })
    }

    func testBookmarksNeedAValidTimeAndAKnownRecording() async throws {
        let library = try await open()
        let id = library.newMeeting()
        let track = RecordingTrack(relativePath: "Originals/a.m4a", fileName: "a.m4a")
        library.update(id) { $0.tracks = [track] }
        library.addBookmark(in: id, at: -3)
        library.addBookmark(in: id, trackID: track.id, at: 12.5)
        library.addBookmark(in: id, trackID: UUID(), at: 12.5)
        library.addBookmark(in: id, trackID: track.id, at: .nan)
        library.addBookmark(in: id, trackID: track.id, at: -1)
        let marks = try XCTUnwrap(library.meeting(id)?.highlights)
        XCTAssertEqual(marks.map(\.time), [0, 12.5], "A recording's time is clamped; playback times must be real")
        XCTAssertEqual(marks.map(\.trackID), [nil, track.id])

        library.setBookmarkText(marks[1].id, text: "Pricing", in: id)
        XCTAssertEqual(library.meeting(id)?.highlights.last?.text, "Pricing")
        library.removeBookmark(marks[0].id, in: id)
        XCTAssertEqual(library.meeting(id)?.highlights.count, 1)
    }

    func testVocabularyIsMirroredIntoTheSyncedSettings() async throws {
        let library = try await open()
        let term = GlossaryTerm(term: "Daybook", approved: true)
        library.saveGlossaryTerm(term)
        XCTAssertEqual(library.metadata.vocabulary.compactMap(\.value), [term])
        library.removeGlossaryTerm(term.id)
        await library.flush()
        XCTAssertTrue(library.glossary.isEmpty)
        XCTAssertEqual(library.metadata.vocabulary.count, 1, "A removal is kept so it syncs")
        XCTAssertNil(library.metadata.vocabulary.first?.value)
    }

    func testTheTrashKeepsAConversationAndCanGiveItBack() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Keep me")
        library.editNotes(id, text: "Notes survive the Trash")
        let refused = try await library.moveToTrash(id, allowed: { false })
        XCTAssertFalse(refused, "Refused while the app says it's busy")
        XCTAssertNotNil(library.meeting(id))

        let moved = try await library.moveToTrash(id)
        XCTAssertTrue(moved)
        XCTAssertNil(library.meeting(id))
        XCTAssertEqual(library.trashedMeetingIDs(), [id])

        let restored = try await library.restoreFromTrash(id)
        XCTAssertEqual(restored.notes, "Notes survive the Trash")
        XCTAssertEqual(library.meeting(id)?.title, "Keep me")
        XCTAssertTrue(library.trashedMeetingIDs().isEmpty)
    }

    func testAFileKeepsItsRecordersIdentityAndIsImportedOnce() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Soundcore Work at 10:02 AM")
        let url = try file("1745312520.wav", "audio bytes")
        let identity = DeviceRecordingIdentity(kind: "soundcore.work", serial: "D320", recordingID: "1745312520")
        let measured = CaptureRecorderClock(offset: 300.4, applied: true, measuredAt: Date(timeIntervalSince1970: 1_745_312_000))
        await library.acquireLock()
        let first = try await library.ingest(url, into: id, provenance: .file(source: .soundcore, device: identity, duration: 61,
                                                                              recorderClock: measured))
        let again = try await library.ingest(url, into: id, provenance: .file(source: .soundcore, device: identity, duration: 61,
                                                                              recorderClock: CaptureRecorderClock(offset: 1, applied: false)))
        library.releaseLock()
        await library.flush()

        let meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.tracks.count, 1, "The same bytes become the same track")
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertEqual(first.track?.id, track.id)
        XCTAssertNil(again.track, "Nothing new arrived the second time")
        XCTAssertEqual(track.device, identity)
        XCTAssertEqual(track.source, .soundcore)
        XCTAssertEqual(track.duration, 61)
        XCTAssertEqual(track.capture, TrackCaptureDetails(recorderClock: measured), "the recorder's clock as measured when it first arrived")
        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(id)?.tracks.first?.capture?.recorderClock, measured, "and saved with it")
        XCTAssertEqual(meeting.status, .imported)
        let stored = try await library.audioURL(for: track, in: id)
        XCTAssertEqual(try Data(contentsOf: stored), Data("audio bytes".utf8), "The original bytes are copied, never moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testACaptureRecordsWhatThisDeviceMeasured() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Conversation")
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let microphone = try file("microphone.caf", "raw microphone")
        let cleaned = try file("microphone-echo-removed.caf", "clean microphone")
        await library.acquireLock()
        let original = try await library.ingest(microphone, into: id, provenance: RecordingProvenance(
            source: .microphone, offset: 0.25, duration: 30, startedAt: started, capture: TrackCaptureDetails(method: "AVAudioEngine"),
            conversationDate: started, message: "The microphone changed during recording."))
        let originalID = try XCTUnwrap(original.track?.id)
        let derived = try await library.ingest(cleaned, into: id, provenance: RecordingProvenance(
            source: .microphone, offset: 0.25, duration: 30, startedAt: started, capture: TrackCaptureDetails(method: "AVAudioEngine"),
            derivedFrom: originalID, processing: RecordingTrack.echoCancelledProcessing, conversationDate: started))
        library.releaseLock()

        let meeting = try XCTUnwrap(library.meeting(id))
        let first = try XCTUnwrap(meeting.tracks.first { $0.id == originalID })
        XCTAssertEqual(first.duration, 30)
        XCTAssertEqual(first.createdAt, started)
        XCTAssertEqual(first.offset, 0.25)
        XCTAssertEqual(first.capture?.method, "AVAudioEngine")
        let second = try XCTUnwrap(meeting.tracks.first { $0.id == derived.track?.id })
        XCTAssertEqual(second.derivedFrom, originalID)
        XCTAssertEqual(second.processing, RecordingTrack.echoCancelledProcessing)
        XCTAssertEqual(meeting.transcribableTracks.map(\.id), [second.id], "The original is transcribed through its cleaned copy")
        XCTAssertEqual(meeting.date, started)
        XCTAssertNil(meeting.errorMessage, "The last capture had no warnings")
    }

    func testRequestsSaveAndSyncLikeEdits() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Phone recording")
        library.update(id) { $0.tracks = [RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", sha256: "a")] }
        let phone = ProcessingRequest.Device(id: "phone", name: "iPhone")
        let mac = ProcessingRequest.Device(id: "mac", name: "Mac Studio")
        let now = Date()
        let request = try XCTUnwrap(library.requestProcessing(id, mode: .newAudio, by: phone, at: now))
        XCTAssertEqual(library.requestProcessing(id, mode: .newAudio, by: phone, at: now)?.id, request.id, "No second request for the same work")
        XCTAssertEqual(library.processingStatus(for: id, at: now), .requested(.device(request)))
        XCTAssertEqual(library.processingRequestsToRun(by: mac, at: now).map(\.id), [request.id])

        XCTAssertNotNil(library.claimProcessingRequest(request.id, in: id, by: mac, at: now, lease: 60))
        XCTAssertNil(library.claimProcessingRequest(request.id, in: id, by: phone, at: now), "Someone else holds it")
        XCTAssertTrue(library.processingRequestsToRun(by: phone, at: now).isEmpty)
        XCTAssertNotNil(library.renewProcessingClaim(request.id, in: id, stage: .summarizing, fraction: 0.8, by: mac,
                                                     at: now.addingTimeInterval(30), lease: 60))
        XCTAssertEqual(library.processingStatus(for: id, at: now.addingTimeInterval(31)),
                       .processing(.init(stage: .summarizing, fraction: 0.8, device: mac)))
        XCTAssertEqual(library.expireStaleClaims(at: now.addingTimeInterval(31)), 0)
        XCTAssertEqual(library.expireStaleClaims(at: now.addingTimeInterval(91)), 1, "The lease ran out a second ago")
        XCTAssertNotNil(library.claimProcessingRequest(request.id, in: id, by: mac, at: now.addingTimeInterval(92)))
        XCTAssertNotNil(library.failProcessingRequest(request.id, in: id, reason: "Download the speech model.", by: mac, at: now.addingTimeInterval(93)))
        XCTAssertNil(library.completeProcessingRequest(request.id, in: id, by: mac, at: now.addingTimeInterval(94)), "Finished is final")
        await library.flush()

        let reopened = try await open()
        let saved = try XCTUnwrap(reopened.meeting(id)?.processingRequests?.first)
        XCTAssertEqual(saved.outcome?.result, .failed)
        XCTAssertEqual(saved.requestedBy, phone)
        guard case .failed(let failure) = try XCTUnwrap(reopened.processingStatus(for: id, at: now.addingTimeInterval(95))) else {
            return XCTFail("Couldn’t finish, with the Mac's reason")
        }
        XCTAssertEqual(failure.reason, "Download the speech model.")
        XCTAssertEqual(reopened.thisDevice.id, "local", "Without a sync folder the replica has no journal identity")
    }

    func testPlacesListTheirConversationsNewestFirst() async throws {
        let library = try await open()
        let older = library.newMeeting(title: "Older", date: Date(timeIntervalSince1970: 1), placement: .personal)
        let newer = library.newMeeting(title: "Newer", date: Date(timeIntervalSince1970: 2), placement: .work)
        XCTAssertEqual(LibraryPlace.section(.all).meetings(in: library.meetings).map(\.id), [newer, older])
        XCTAssertEqual(LibraryPlace.section(.work).meetings(in: library.meetings).map(\.id), [newer])
        XCTAssertEqual(LibraryPlace.section(.personal).meetings(in: library.meetings).map(\.id), [older])
        XCTAssertTrue(LibraryPlace.device("soundcore").meetings(in: library.meetings).isEmpty)
        let hits = LibrarySearch.hits(in: library.meetings, text: "new", tokens: [], scope: .all)
        XCTAssertEqual(hits.map(\.meetingID), [newer])
    }
}
