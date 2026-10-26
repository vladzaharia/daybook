import DaybookCaptions
import Combine
import DaybookKit
import UIKit
import XCTest
@testable import DaybookPhone

/// The library and reading: loading a Mac library, the words for processing states, evidence,
/// the transcript's shape, playback targets, Version History's marks, export, and the session that
/// carries reading across folds.
@MainActor
final class ReadingTests: XCTestCase {
    // MARK: Fixtures

    private let trackID = UUID()
    private let phone = ProcessingRequest.Device(id: "local", name: "Alex's iPhone")
    private let studio = ProcessingRequest.Device(id: "mac-studio", name: "Studio")
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The seeded demo's "Weekly product sync": three speakers, a summary, a note, a bookmark.
    private func weekly() -> Meeting {
        let lines: [(Int, String, Double, Double)] = [
            (0, "Okay, let's get started. The main thing today is whether the beta ships on the fourteenth.", 0, 5.2),
            (1, "Engineering is mostly there. Sync conflict handling is the last open piece, and I'd like two more days of testing on it.", 5.6, 12.9),
            (2, "Support is ready either way. We drafted the help articles last week, so it's really about the release notes.", 13.3, 19.8),
            (0, "Then let's hold the fourteenth, but make the conflict fix the gate. If it isn't green by Friday, we move a week.", 20.2, 26.6),
            (1, "That works. I'll post a status in the channel Thursday afternoon.", 27.0, 31.4),
            (2, "One more thing: three customers asked about exporting to Markdown. Is that in the beta?", 31.8, 37.6),
            (2, "Release notes are on me.", 37.9, 39.0),
            (1, "I can review the release notes too.", 39.4, 41.0),
        ]
        let speakers = ["Maya", "Daniel", "Priya"].enumerated().map { Speaker(id: "S\($0.offset)", name: $0.element, sourceTrackID: trackID) }
        let segments = lines.map { speaker, text, start, end -> TranscriptSegment in
            let id = UUID()
            return TranscriptSegment(id: id, trackID: trackID, start: start, end: end, text: text, speakerID: "S\(speaker)",
                                     provenance: [SegmentProvenance(trackID: trackID, segmentID: id, start: start, end: end, text: text)])
        }
        let summary = MeetingSummary(overview: "The team agreed to keep the beta date of the 14th, gated on the sync conflict fix.",
                                     sections: [SummarySection(heading: "Decisions", body: "- Keep the **14th** as the beta date.\n- The sync conflict fix is the release gate.")],
                                     actionItems: [ActionItem(text: "Post a status update on the conflict fix", owner: "Daniel"),
                                                   ActionItem(text: "Finish the release notes, including Markdown export", owner: "Priya")],
                                     createdAt: now.addingTimeInterval(-3600))
        return Meeting(title: "Weekly product sync", date: now.addingTimeInterval(-7200), kind: .general,
                       notes: "Beta date — hold the 14th?\nAsk about export for the release notes",
                       tracks: [RecordingTrack(id: trackID, source: .microphone, relativePath: "Originals/Microphone.wav", fileName: "Microphone.wav",
                                               duration: 41.5, offset: 0)],
                       transcripts: [TrackTranscript(trackID: trackID, segments: segments, modelID: "whisper-small", createdAt: now.addingTimeInterval(-3700))],
                       unifiedTranscript: segments, summary: summary,
                       highlights: [Highlight(time: 14.5, text: "Gate on the conflict fix")], speakers: speakers, status: .ready,
                       timedNotes: [TimedNote(time: 2, text: "Beta date — hold the 14th?"), TimedNote(time: 24, text: "Ask about export for the release notes")])
    }

    private func recorded() -> Meeting {
        Meeting(title: "Onboarding design review", date: now, tracks: [RecordingTrack(id: trackID, source: .microphone, relativePath: "Originals/a.m4a",
                                                                                         fileName: "a.m4a", duration: 11, offset: 0)],
                status: .imported)
    }

    // MARK: The demo library

    /// A library written by the Mac (JSON with reference-date seconds, as the demo seeder writes)
    /// loads, and the controller tells observers, which the list relies on: the app model's
    /// `PhoneLibrary.conversations` isn't observable, so the list observes the controller itself.
    func testAMacLibraryLoadsAndPublishesItsConversations() async throws {
        let root = try temporaryDirectory()
        let id = UUID()
        let directory = root.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "schemaVersion": 1, "id": id.uuidString, "title": "Weekly product sync", "date": 800_000_000.0, "updatedAt": 800_003_600.0,
            "kind": "auto", "notes": "Beta date?", "tracks": [], "transcripts": [], "unifiedTranscript": [], "alignmentReports": [],
            "revisions": [], "highlights": [], "speakers": [], "status": "ready", "folderID": UUID().uuidString, "tags": ["launch"],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("meeting.json"))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "folders": [], "templates": [], "vocabulary": []] as [String: Any])
            .write(to: root.appendingPathComponent("library.json"))

        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        var published = 0
        let observation = library.controller.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        XCTAssertTrue(library.controller.meetings.isEmpty, "nothing before the app's launch loads it")
        try await library.reload()
        XCTAssertGreaterThan(published, 0, "views observing the controller redraw once it loads")
        XCTAssertEqual(LibraryPlace.section(.all).meetings(in: library.controller.meetings).map(\.title), ["Weekly product sync"])
        XCTAssertEqual(library.controller.allTags, ["launch"])
    }

    // MARK: Processing states

    func testRecordedIsACalmCompleteState() {
        let meeting = recorded()
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .recorded)
        let page = StatusPresentation.page(.recorded, meeting: meeting, sighting: nil, now: now)
        XCTAssertEqual(page?.kind, .line)
        XCTAssertEqual(page?.title, "Not transcribed yet")
        XCTAssertEqual(page?.actions, [])
        XCTAssertEqual(StatusPresentation.row(.recorded), RowStatus(kind: .notTranscribed, text: "Not transcribed yet"))
    }

    func testWaitingSaysWhenAMacWasLastSeen() {
        var meeting = recorded()
        meeting.upsertProcessingRequest(ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now))
        let status = ProcessingStatus(meeting, now: now)
        guard case .requested(.device) = status else { return XCTFail("expected a request waiting for a Mac, got \(status)") }

        let old = StatusPresentation.page(status, meeting: meeting, sighting: MacSighting(name: "Studio", date: now.addingTimeInterval(-2 * 3600)), now: now)
        XCTAssertEqual(old?.title, "Waiting for your Mac")
        XCTAssertEqual(old?.detail, "Last seen 2 h ago")
        let recent = StatusPresentation.page(status, meeting: meeting, sighting: MacSighting(name: "Studio", date: now.addingTimeInterval(-60)), now: now)
        XCTAssertNil(recent?.detail, "a Mac that checked in recently needs no excuse")
        let never = StatusPresentation.page(status, meeting: meeting, sighting: nil, now: now)
        XCTAssertEqual(never?.detail, "No Mac has checked in yet. Open Daybook on your Mac.")
        XCTAssertEqual(StatusPresentation.row(status)?.text, "Waiting for your Mac")
        XCTAssertEqual(StatusPresentation.waitingTitle(.summaryOnly), "Waiting for your Mac to summarize again")
    }

    func testProcessingNamesTheMacAndNeverInventsProgress() {
        let reported = ProcessingStatus.Progress(stage: .transcribing, fraction: 0.4, device: studio)
        let page = StatusPresentation.page(.processing(reported), meeting: recorded(), sighting: nil, now: now)
        XCTAssertEqual(page?.title, "Transcribing on Studio · 40%")
        XCTAssertEqual(page?.progress, 0.4)
        XCTAssertEqual(page?.isWorking, false)

        let silent = ProcessingStatus.Progress(stage: .summarizing, fraction: nil, device: studio)
        let line = StatusPresentation.page(.processing(silent), meeting: recorded(), sighting: nil, now: now)
        XCTAssertEqual(line?.title, "Summarizing on Studio")
        XCTAssertNil(line?.progress, "no figure, no bar")
        XCTAssertEqual(line?.isWorking, true)
        XCTAssertEqual(StatusPresentation.row(.processing(reported)), RowStatus(kind: .processing, text: "Transcribing on Studio · 40%", fraction: 0.4))
    }

    func testCouldntFinishOffersTryAgainWithTheFailedRequestsMode() {
        var meeting = weekly()
        let request = ProcessingRequest(meetingID: meeting.id, mode: .speakerRefresh, requestedBy: phone, createdAt: now)
        let failed = request.failed(by: studio, at: now, reason: "The speaker model isn't downloaded")!
        meeting.upsertProcessingRequest(failed)
        let status = ProcessingStatus(meeting, now: now)
        guard case .failed(let failure) = status else { return XCTFail("expected a failure, got \(status)") }
        let page = StatusPresentation.page(status, meeting: meeting, sighting: nil, now: now)
        XCTAssertEqual(page?.kind, .problem)
        XCTAssertEqual(page?.title, "Couldn’t finish summarizing")
        XCTAssertEqual(page?.detail, "The models it needs aren’t on Studio yet. The recording is saved.")
        XCTAssertEqual(page?.actions, [.request(.speakerRefresh), .details(failure.reason)])

        // Trying again can't find speech that isn't there.
        let silent = StatusPresentation.page(.failed(.init(reason: "No speech was recognized.", hadTranscripts: false)), meeting: recorded(), sighting: nil, now: now)
        XCTAssertEqual(silent?.title, "No speech in this recording")
        XCTAssertEqual(silent?.actions, [.details("No speech was recognized.")])
    }

    func testTheLastSightingIsTheNewestSignOfAMacAtWork() {
        var meeting = recorded()
        var request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: phone, createdAt: now.addingTimeInterval(-600))
        request = request.claimed(by: studio, at: now.addingTimeInterval(-300))!
        meeting.upsertProcessingRequest(request)
        let sighting = MacSighting.latest(in: [weekly(), meeting], excluding: phone.id)
        XCTAssertEqual(sighting, MacSighting(name: "Studio", date: now.addingTimeInterval(-300)))
        XCTAssertNil(MacSighting.latest(in: [recorded()], excluding: phone.id))
        XCTAssertEqual(MacSighting.ago(3 * 86_400), "3 days ago")
    }

    // MARK: Evidence

    func testNextStepsAndBulletsFindTheirEvidence() {
        let meeting = weekly()
        let index = EvidenceIndex(meeting)
        let text = { (id: UUID?) in meeting.unifiedTranscript.first { $0.id == id }?.text }
        XCTAssertEqual(text(index.segment(for: "Post a status update on the conflict fix", owner: "Daniel")),
                       "That works. I'll post a status in the channel Thursday afternoon.")
        XCTAssertEqual(text(index.segment(for: "The sync conflict fix is the release gate.")),
                       "Then let's hold the fourteenth, but make the conflict fix the gate. If it isn't green by Friday, we move a week.")
        // The owner's own passage wins over equally good ones.
        XCTAssertEqual(text(index.segment(for: "Release notes", owner: "Daniel")), "I can review the release notes too.")
        XCTAssertEqual(text(index.segment(for: "Release notes")), meeting.unifiedTranscript[2].text, "without an owner, the first")
        XCTAssertNil(index.segment(for: "Lunch is at noon"), "nothing shared, nothing found")
        XCTAssertEqual(["notes", "status", "boxes", "stories", "drafted", "testing"].map(EvidenceIndex.stem),
                       ["note", "status", "box", "story", "draft", "test"])
        XCTAssertNil(index.segment(for: "The team will make the thing well"), "common words aren't evidence")
    }

    // MARK: Saved live captions

    func testLiveCaptionsStandInOnlyUntilTheMacsTranscriptArrives() throws {
        let meeting = recorded()
        let captions = LiveCaptions(meetingID: meeting.id, trackID: trackID, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0.4, end: 3.1, text: "The new onboarding has three screens.", isTentative: false),
            LiveCaptionSegment(start: 3.2, end: 5.4, text: "The model download moved", isTentative: true),
        ])
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting), captions)
        XCTAssertNil(SavedCaptions.shown(captions, for: weekly()), "another conversation's captions never show")
        var transcribed = meeting
        transcribed.transcripts = [TrackTranscript(trackID: trackID, segments: [], modelID: "whisper")]
        XCTAssertNil(SavedCaptions.shown(captions, for: transcribed), "the Mac's transcript replaces them")
        XCTAssertNil(SavedCaptions.shown(LiveCaptions(meetingID: meeting.id, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0, end: 1, text: "  ", isTentative: true)]), for: meeting), "nothing to read, nothing shown")

        XCTAssertEqual(SavedCaptions.playback(captions.segments[1], captions: captions, in: meeting), .source(meeting.tracks[0], 3.2),
                       "a caption's time plays the phone's recording")
        XCTAssertEqual(SavedCaptions.playing(at: 4, trackID: trackID, captions: captions, in: meeting), captions.segments[1].id)
        XCTAssertNil(SavedCaptions.playing(at: 4, trackID: UUID(), captions: captions, in: meeting))
        XCTAssertEqual(ProcessingStatus(meeting, now: now), .recorded, "captions don't change the processing state")
        XCTAssertNil(EvidenceIndex(meeting).segment(for: "three screens onboarding"), "captions are never evidence")

        let store = LiveCaptionStore(libraryRoot: try temporaryDirectory())
        try store.save(captions)
        let hits = SavedCaptions.hits(in: [meeting, weekly()], query: "download", store: store)
        XCTAssertEqual(hits.map(\.meeting.id), [meeting.id])
        XCTAssertEqual(hits.first?.segment.text, "The model download moved")
        XCTAssertTrue(SavedCaptions.hits(in: [transcribed], query: "download", store: store).isEmpty)
    }

    // MARK: The transcript

    func testTurnsGroupASpeakersPassagesAndNotesSitAtTheirTimes() {
        let meeting = weekly()
        let rows = TranscriptRow.rows(in: meeting)
        let turns = rows.compactMap { row -> String? in if case .turn(let speaker, _) = row { return speaker } else { return nil } }
        XCTAssertEqual(turns, ["S0", "S1", "S2", "S0", "S1", "S2", "S1"], "Priya's last two passages are one turn")
        let notes = rows.enumerated().compactMap { index, row -> Int? in if case .note = row { return index } else { return nil } }
        XCTAssertEqual(notes.count, 2)
        guard case .passage(let before) = rows[notes[1] - 1] else { return XCTFail("a passage before the 0:24 note") }
        XCTAssertEqual(before.start, 20.2, "the 0:24 note follows the passage it was written during")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "every row is its own scroll target")
    }

    func testABookmarkMarksThePassageItFallsIn() {
        let meeting = weekly()
        let marks = BookmarkMarks(meeting: meeting)
        let holder = meeting.unifiedTranscript[2].id
        XCTAssertEqual(marks.holders, [holder])
        XCTAssertEqual(marks.labelSegments[holder], "Gate on the conflict fix")
        XCTAssertEqual(BookmarkMarks.holder(of: meeting.highlights[0], in: meeting), holder)
    }

    func testPhotosAppearAtTheirTimesAndBreakSpeakerTurns() {
        var meeting = weekly()
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "",
                                 capturedAt: now, time: 5.4, caption: "Whiteboard")
        meeting.photos = [photo]
        let rows = TranscriptRow.rows(in: meeting)
        let index = rows.firstIndex { $0.id == photo.id.uuidString }
        XCTAssertNotNil(index)
        if let index, case .photo(let placed, let time) = rows[index] {
            XCTAssertEqual(placed.id, photo.id)
            XCTAssertEqual(time, 5.4)
            XCTAssertGreaterThan(index, 0)
            XCTAssertLessThan(index, rows.count - 1)
        } else { XCTFail("The photo needs its own transcript row") }
        meeting.removePhoto(photo.id)
        XCTAssertFalse(TranscriptRow.rows(in: meeting).contains { $0.id == photo.id.uuidString })
    }

    func testThePhotoProviderReadsAnOriginalAndReportsMissingPhotos() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        try await library.reload()
        let id = library.controller.newMeeting(title: "Photos")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40))
        let bytes = renderer.pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        await library.controller.acquireLock()
        let photo = try await library.controller.addPhoto(data: bytes, to: id)
        library.controller.releaseLock()
        let provider = LocalAudioProvider(library: library)
        let url = try await provider.localPhoto(for: photo, in: id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(PhotoImage.thumbnail(url, maxPixels: 40))
        let meeting = try XCTUnwrap(library.controller.meeting(id))
        let archive = try ExportFiles.markdownWithPhotos(meeting, originals: [photo.id: url], in: root)
        XCTAssertEqual(archive.pathExtension, "zip")
        XCTAssertEqual(Array(try Data(contentsOf: archive).prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await provider.localPhoto(for: photo, in: id)
            XCTFail("A missing photo must be reported")
        } catch {
            XCTAssertTrue(error is PhotoProvidingError)
        }
    }

    func testPlaybackTargetsResolveToARecordingAndATime() throws {
        let meeting = weekly()
        let passage = meeting.unifiedTranscript[3]
        let resolved = try XCTUnwrap(PlaybackTarget.segment(passage).resolve(in: meeting))
        XCTAssertEqual(resolved.track.id, trackID)
        XCTAssertEqual(resolved.seconds, 20.2)
        XCTAssertEqual(PlaybackTarget.timeline(24).resolve(in: meeting)?.seconds, 24)
        XCTAssertEqual(PlaybackTarget.source(meeting.tracks[0], -3).resolve(in: meeting)?.seconds, 0)
        XCTAssertNil(PlaybackTarget.timeline(3).resolve(in: Meeting(title: "Notes only")))

        XCTAssertEqual(TranscriptFollow.segmentID(at: 15, trackID: trackID, in: meeting), meeting.unifiedTranscript[2].id)
        XCTAssertNil(TranscriptFollow.segmentID(at: 13.1, trackID: trackID, in: meeting), "between passages, nothing is playing")
    }

    func testSummaryLinesSplitLikeTheMacsMarkdown() {
        let lines = SummaryLine.lines("Intro line\ncontinued\n\n- First\n* Second\n2. Numbered\n## Heading")
        XCTAssertEqual(lines, [.paragraph("Intro line\ncontinued"), .item(marker: "•", text: "First"), .item(marker: "•", text: "Second"),
                               .item(marker: "2.", text: "Numbered"), .heading("Heading")])
    }

    // MARK: Version History and export

    func testWordDiffMarksOnlyTheWordsThatChanged() {
        let changes = WordDiff.changes(old: WordDiff.tokens("The sink conflict fix"), new: WordDiff.tokens("The sync conflict fix"))
        XCTAssertEqual(Array(changes.removed), [1])
        XCTAssertEqual(Array(changes.inserted), [1])
        let marked = WordDiff.marked(old: "The sink conflict fix", new: "The sync conflict fix")
        XCTAssertEqual(String(marked.new.characters), "The sync conflict fix", "marking never changes the text")
    }

    func testMarkdownExportIsAFileNamedAfterTheConversation() throws {
        var meeting = weekly()
        meeting.title = "Q4: launch / beta?"
        let url = try ExportFiles.markdown(meeting, in: try temporaryDirectory())
        XCTAssertEqual(url.lastPathComponent, "Q4- launch - beta-.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Q4: launch / beta?"))
        XCTAssertTrue(text.contains("**Daniel:** That works."))
        XCTAssertEqual(ExportFiles.fileName("  ...  "), "Conversation")
    }

    /// Exports wait in tmp only until the share sheet is done; a library original handed to it
    /// is never removed.
    func testSharedExportsAreClearedAndNothingElseIs() throws {
        let directory = try temporaryDirectory()
        let meeting = weekly()
        let first = try ExportFiles.markdown(meeting, in: directory)
        var other = weekly()
        other.id = UUID()
        let second = try ExportFiles.markdown(other, in: directory)
        let original = directory.appendingPathComponent("Library/Originals/Photos/a.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: original)

        ExportFiles.clear([first, original], in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "another export waits for its own share sheet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "never a file outside the exports")

        ExportFiles.clear(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExportFiles.root(in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    // MARK: Copy

    private final class PasteboardRecorder: LocalPasteboardWriting {
        var writes: [(items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any])] = []
        func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) { writes.append((items, options)) }
    }

    func testCopiedTextStaysOnThisIPhone() {
        let recorder = PasteboardRecorder()
        LocalPasteboard.copy("We agreed on Friday.", to: recorder)
        XCTAssertEqual(recorder.writes.count, 1)
        XCTAssertEqual(recorder.writes.first?.options[.localOnly] as? Bool, true, "never Universal Clipboard")
        XCTAssertNil(recorder.writes.first?.options[.expirationDate])
        XCTAssertEqual(recorder.writes.first?.items.first?["public.utf8-plain-text"] as? String, "We agreed on Friday.")

        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        LocalPasteboard.copy("Ship it", to: pasteboard)
        XCTAssertEqual(pasteboard.string, "Ship it")
    }

    // MARK: The session across folds

    func testANewNoteIsAConversationWithoutAudioInThePlaceBeingViewed() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "TEST")
        try await library.reload()
        let session = ReadingSession()
        session.place = .library(.section(.work))
        let id = session.newNote(in: library.controller)
        let meeting = try XCTUnwrap(library.controller.meeting(id))
        XCTAssertTrue(meeting.title.hasPrefix("Note at "))
        XCTAssertTrue(meeting.tracks.isEmpty)
        XCTAssertEqual(meeting.placement, .work)
        XCTAssertEqual(ProcessingStatus(meeting), .done, "nothing to transcribe, nothing to wait for")
        XCTAssertEqual(session.openID, id)
        XCTAssertTrue(session.reading)
        XCTAssertEqual(session.pageMode, .summary)
        XCTAssertEqual(session.focusNotesFor, id)

        let folder = library.controller.createFolder(named: "Ideas")
        session.place = .library(.folder(folder))
        let filed = try XCTUnwrap(library.controller.meeting(session.newNote(in: library.controller)))
        XCTAssertEqual(filed.folderID, folder)
    }

    func testTheSessionCarriesReadingAcrossLayouts() throws {
        let session = ReadingSession()
        let first = UUID(), second = UUID(), segment = UUID()
        session.select(first)
        XCTAssertFalse(session.reading, "on two pages a tap shows the page beside the list")
        XCTAssertTrue(session.chosen)
        session.isNotebook = true
        session.showInTranscript(segment)
        XCTAssertTrue(session.reading, "a jump to the transcript opens the spread on two pages")
        XCTAssertEqual(session.pageMode, .transcript)
        XCTAssertEqual(session.transcriptRequest?.target, segment.uuidString)
        XCTAssertEqual(session.flashedSegment, segment)

        session.transcriptAnchor = segment.uuidString
        session.open(second)
        XCTAssertNil(session.transcriptAnchor, "another conversation opens at its top")
        session.forget(second)
        XCTAssertNil(session.openID)
        XCTAssertFalse(session.reading)

        let meeting = weekly()
        let hit = try XCTUnwrap(LibrarySearch.hits(in: [meeting], text: "Thursday afternoon", tokens: [], scope: .all).first)
        XCTAssertEqual(hit.field, .transcript)
        session.isNotebook = false
        session.pageMode = .summary
        session.open(hit)
        XCTAssertEqual(session.openID, meeting.id)
        XCTAssertTrue(session.reading)
        XCTAssertEqual(session.pageMode, .transcript, "a passage hit opens at the passage")
        XCTAssertEqual(session.transcriptRequest?.target, hit.segmentID?.uuidString)
        XCTAssertNotEqual(first, segment)
    }

    func testTheCreaseIsTheMiddleOfTheWholeDisplay() {
        // iPhone Duo open: 951 pt wide, the status bar column takes 84 pt on the right.
        XCTAssertEqual(CreaseGeometry.crease(width: 867, leadingInset: 0, trailingInset: 84), 475.5)
        XCTAssertEqual(CreaseGeometry.crease(width: 874, leadingInset: 0, trailingInset: 0), 437)
        XCTAssertEqual(CreaseGeometry.crease(width: 300, leadingInset: 0, trailingInset: 400), 300, "never outside the view")
    }

    func testLaunchArgumentsAreReadInDebugBuilds() {
        let launch = ReadingLaunch(arguments: ["app", "--select", "Weekly", "--page", "transcript", "--play", "--sheet", "history"])
        XCTAssertEqual(launch.select, "Weekly")
        XCTAssertEqual(launch.page, .transcript)
        XCTAssertEqual(launch.play, 0)
        XCTAssertEqual(launch.sheet, "history")
        XCTAssertTrue(ReadingLaunch(arguments: ["app"]).isEmpty)
    }

    // MARK: The notes editor

    func testTheNotesEditorPutsEachTimeOnItsParagraph() {
        let view = MarginTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        view.times = [2, nil, 75]
        view.setText("First thought\n\nUntimed line\nA much longer third paragraph that wraps onto a second line at this width, surely")
        let times = view.laneTimes
        XCTAssertEqual(times.map(\.text), ["0:02", "1:15"], "the untimed paragraph shows no time; blank lines aren't paragraphs")
        XCTAssertLessThan(times[0].baseline, times[1].baseline)
        XCTAssertGreaterThan(view.height(forWidth: 320), view.height(forWidth: 2000), "it grows as the text wraps")

        view.baseLane = 0
        XCTAssertEqual(view.laneTimes.count, 0, "no lane, no times")
    }

    // MARK: Audio

    func testTheLocalProviderPlaysOnlyWhatIsOnThisIPhone() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: "Played")
        rig.pump(2)
        let meeting = try await library.file(try await rig.stop())
        let track = try XCTUnwrap(meeting.tracks.first)

        let provider = LocalAudioProvider(library: library)
        let availability = await provider.availability(of: track, in: meeting.id)
        XCTAssertEqual(availability, .local)
        let url = try await provider.localAudio(for: track, in: meeting.id) { _ in }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))

        // Evicted (or never downloaded): it says so, and doesn't pretend to fetch it.
        try FileManager.default.removeItem(at: url)
        let gone = await provider.availability(of: track, in: meeting.id)
        XCTAssertEqual(gone, .offline)
        do {
            _ = try await provider.localAudio(for: track, in: meeting.id) { _ in }
            XCTFail("an evicted file can't play")
        } catch {
            XCTAssertEqual(error as? AudioProvidingError, .offline)
            XCTAssertEqual(error.localizedDescription, "The audio isn’t on this iPhone yet. It downloads when you’re online.")
        }
        do {
            _ = try await LocalAudioProvider().localAudio(for: track, in: meeting.id) { _ in }
            XCTFail("the unbound default has no library")
        } catch {
            XCTAssertEqual(error as? AudioProvidingError, .notConfigured)
        }
    }

    func testTheTrashListsWhatWasMovedThere() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "TEST")
        try await library.reload()
        let kept = library.controller.newMeeting(title: "Kept")
        let trashed = library.controller.newMeeting(title: "Offsite ideas")
        await library.controller.flush()
        let moved = try await library.controller.moveToTrash(trashed)
        XCTAssertTrue(moved)
        let listed = TrashedConversations.load(rootURL: root, ids: library.controller.trashedMeetingIDs())
        XCTAssertEqual(listed.map(\.title), ["Offsite ideas"])
        try await library.controller.restoreFromTrash(trashed)
        XCTAssertEqual(Set(library.controller.meetings.map(\.id)), [kept, trashed])
        XCTAssertTrue(TrashedConversations.load(rootURL: root, ids: library.controller.trashedMeetingIDs()).isEmpty)
    }
}
