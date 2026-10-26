import XCTest
@testable import DaybookCore

final class PhotoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPhotoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private var library: URL { root.appendingPathComponent("Library") }
    private func source(_ name: String, seed: Int = 0) throws -> URL {
        try SyntheticPhotos.write(SyntheticPhotos.data(seed: seed), named: name, in: root.appendingPathComponent("Sources"))
    }

    // MARK: Old libraries

    func testMeetingsWrittenBeforePhotosDecodeUnchangedAndReencodeWithoutPhotoKeys() throws {
        // A meeting.json as Daybook wrote it before photos: no "photos", sections without "photoIDs".
        let id = UUID(), section = UUID()
        let legacy = """
        {"schemaVersion":1,"id":"\(id.uuidString)","title":"Planning","date":780000000,"updatedAt":780000100,"kind":"general",
         "notes":"Ship it","tracks":[],"transcripts":[],"unifiedTranscript":[],"alignmentReports":[],"revisions":[],
         "highlights":[],"speakers":[],"status":"ready",
         "summary":{"kind":"general","title":"Planning","overview":"We planned.","sections":[{"id":"\(section.uuidString)","heading":"Decisions","body":"Ship."}],
                    "actionItems":[],"modelID":"gemma-4/e2b-4bit","createdAt":780000050}}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(meeting.photos)
        XCTAssertEqual(meeting.summary?.sections.first?.photoIDs, nil)
        XCTAssertTrue(meeting.visiblePhotos.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(meeting), as: UTF8.self)
        XCTAssertFalse(text.contains("photos")); XCTAssertFalse(text.contains("photoIDs"))
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: encoder.encode(meeting)), meeting)
    }

    // MARK: Storage

    func testDamagedStoredPhotoDoesNotSuppressAHealthyReimport() async throws {
        let store = try MeetingStore(rootURL: library)
        var meeting = Meeting(title: "Photo recovery")
        let original = try source("original.png")
        let first = try await store.storePhoto(from: original, in: meeting, capturedAt: Date(), capturedAtSource: .added)
        meeting.addPhoto(first)
        let damagedURL = try await store.photoURL(for: first, in: meeting.id)
        try Data("damaged".utf8).write(to: damagedURL)
        let recovered = try await store.storePhoto(from: original, in: meeting, capturedAt: Date(), capturedAtSource: .added)
        let recoveredURL = try await store.photoURL(for: recovered, in: meeting.id)
        XCTAssertNotEqual(recovered.id, first.id)
        XCTAssertEqual(try Data(contentsOf: recoveredURL), try Data(contentsOf: original))
        XCTAssertEqual(try Data(contentsOf: damagedURL), Data("damaged".utf8), "Retain the damaged artifact for recovery history")
    }

    func testPhotoOriginalIsStoredAsIsAndSurvivesAStaleSnapshotTrashAndRestore() async throws {
        let store = try MeetingStore(rootURL: library)
        var meeting = Meeting(title: "Whiteboard review")
        try await store.save(meeting)
        let file = try source("IMG_0412.PNG")
        let photo = try await store.storePhoto(from: file, in: meeting, capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                               capturedAtSource: .metadata, origin: PhotoOrigin(kind: PhotoOrigin.macKind, name: "Studio Mac"))
        XCTAssertTrue(photo.relativePath.hasPrefix("Originals/Photos/\(photo.id.uuidString)"))
        XCTAssertEqual(photo.relativePath.split(separator: ".").last, "png")
        XCTAssertEqual(photo.fileName, "IMG_0412.PNG")
        XCTAssertEqual(photo.contentType, "public.png")
        XCTAssertEqual(photo.sha256, try AudioDigest.sha256(fileURL: file))
        let stale = meeting
        meeting.addPhoto(photo)
        try await store.save(meeting)
        // An older snapshot queued before the photo arrived can't drop it.
        try await store.save(stale)
        let loaded = try await store.load(meeting.id)
        XCTAssertEqual(loaded.photos?.map(\.id), [photo.id])
        let stored = try await store.photoURL(for: photo, in: meeting.id)
        XCTAssertEqual(try Data(contentsOf: stored), try Data(contentsOf: file), "the original's bytes are kept as is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the source is never moved")

        _ = try await store.moveToTrash(meeting.id)
        let restored = try await store.restoreFromTrash(meeting.id)
        XCTAssertEqual(restored.photos, loaded.photos)
        let back = try await store.photoURL(for: photo, in: meeting.id)
        XCTAssertEqual(try Data(contentsOf: back), try Data(contentsOf: file))
    }

    func testTheSameBytesBecomeOnePhotoAndOtherFilesAreRefused() async throws {
        let store = try MeetingStore(rootURL: library)
        var meeting = Meeting(title: "Slides")
        try await store.save(meeting)
        let first = try await store.storePhoto(from: try source("a.png"), in: meeting, capturedAt: Date(), capturedAtSource: .added)
        meeting.addPhoto(first)
        let again = try await store.storePhoto(from: try source("copy.png"), in: meeting, capturedAt: Date(), capturedAtSource: .added)
        XCTAssertEqual(again.id, first.id)
        let text = try SyntheticPhotos.write(Data("not an image".utf8), named: "notes.png", in: root)
        do { _ = try await store.storePhoto(from: text, in: meeting, capturedAt: Date(), capturedAtSource: .added); XCTFail("accepted text") }
        catch { XCTAssertTrue(error is PhotoStoreError) }
        XCTAssertEqual(PhotoFormat.detect(SyntheticPhotos.data(.jpeg)), .jpeg)
        XCTAssertEqual(PhotoFormat.detect(SyntheticPhotos.data(.png)), .png)
        XCTAssertEqual(PhotoFormat.detect(SyntheticPhotos.data(.heic)), .heic)
    }

    func testDeletingAPhotoKeepsItsFileAndHistoryAndPutsBackWhereItWas() throws {
        var meeting = Meeting(title: "Design")
        let photo = MeetingPhoto(relativePath: MeetingPhoto.relativePath(id: UUID(), extension: "jpg"), fileName: "a.jpg",
                                 sha256: String(repeating: "a", count: 64), capturedAt: Date(), time: 30)
        meeting.addPhoto(photo)
        meeting.summary = MeetingSummary(overview: "Sketches", sections: [SummarySection(heading: "Design", body: "Layouts", photoIDs: [photo.id])])
        meeting.removePhoto(photo.id)
        XCTAssertTrue(meeting.visiblePhotos.isEmpty)
        XCTAssertEqual(meeting.photos?.count, 1, "the record stays")
        XCTAssertTrue(meeting.photos(in: meeting.summary!.sections[0]).isEmpty, "a deleted photo isn't shown in the summary")
        XCTAssertEqual(meeting.revisions.map(\.newValue), ["added", "removed"])
        meeting.restorePhoto(photo.id)
        XCTAssertEqual(meeting.photos(in: meeting.summary!.sections[0]).map(\.id), [photo.id], "back under its section")
        XCTAssertEqual(meeting.revisions.last?.newValue, "present")
        meeting.setPhotoCaption(photo.id, caption: "  Layout sketches ")
        XCTAssertEqual(meeting.photo(photo.id)?.displayCaption, "Layout sketches")
        meeting.setPhotoHiddenFromSummary(photo.id, hidden: true)
        XCTAssertNil(meeting.summary?.sections[0].photoIDs)
    }

    // MARK: The timeline

    private func track(_ source: AudioSource = .microphone, offset: TimeInterval? = 0, startedAt: Date? = nil,
                       device: DeviceRecordingIdentity? = nil, alignment: SourceAlignment? = nil, captured: Bool = true) -> RecordingTrack {
        var value = RecordingTrack(source: source, relativePath: "Originals/\(UUID().uuidString).m4a", fileName: "a.m4a", duration: 600,
                                   offset: offset, sha256: String(repeating: "b", count: 64), device: device, startedAt: startedAt, alignment: alignment)
        if captured && device == nil { value.capture = TrackCaptureDetails() }
        return value
    }

    func testPhotosLandOnTheTimelineLikeBookmarks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let mic = track(startedAt: start)
        var meeting = Meeting(title: "Standup", date: start, tracks: [mic])
        // Taken on this Mac while it recorded: the capture clock is the timeline.
        let during = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "", capturedAt: start.addingTimeInterval(95), time: 95)
        XCTAssertEqual(meeting.timelineTime(of: during), 95)
        // Imported later with its EXIF moment: placed by the wall clock.
        let imported = MeetingPhoto(relativePath: "Originals/Photos/b.jpg", fileName: "b.jpg", sha256: "", capturedAt: start.addingTimeInterval(300),
                                    capturedAtSource: .metadata)
        XCTAssertEqual(meeting.timelineTime(of: imported)!, 300, accuracy: 0.001)
        // A photo of another day isn't on this timeline.
        let elsewhere = MeetingPhoto(relativePath: "Originals/Photos/c.jpg", fileName: "c.jpg", sha256: "", capturedAt: start.addingTimeInterval(86_400))
        XCTAssertNil(meeting.timelineTime(of: elsewhere))
        meeting.photos = [imported, during, elsewhere]
        XCTAssertEqual(meeting.visiblePhotos.map(\.fileName), ["a.jpg", "b.jpg", "c.jpg"])
        // A conversation with no recordings has no timeline.
        XCTAssertNil(Meeting(title: "Notes only").timelineTime(of: imported))
    }

    func testAPhotoFromTheCompanionIPhoneDuringAMultipointRecordingFollowsItsRecordingsPlacement() {
        let macStart = Date(timeIntervalSince1970: 1_800_000_000)
        // The phone's clock runs 2.5 s ahead of the Mac's; its recording started 4 s after the Mac's.
        let phoneClockAhead: TimeInterval = 2.5
        let phoneStart = macStart.addingTimeInterval(4 + phoneClockAhead)
        let identity = DeviceRecordingIdentity(kind: "daybook.iphone", serial: "install-1", recordingID: UUID().uuidString)
        let mic = track(startedAt: macStart)
        // Waiting to be lined up, with the clock prior the link measured (4 s).
        var phone = track(offset: nil, startedAt: phoneStart, device: identity, alignment: SourceAlignment(method: .pending, clockOffset: 4.0))
        var meeting = Meeting(title: "Design review", date: macStart, tracks: [mic, phone])
        let origin = PhotoOrigin(kind: "daybook.iphone", serial: "install-1", name: "Alex's iPhone")
        let whiteboard = MeetingPhoto(relativePath: "Originals/Photos/w.heic", fileName: "w.heic", sha256: "",
                                      capturedAt: phoneStart.addingTimeInterval(60), capturedAtSource: .camera,
                                      trackID: phone.id, time: 60, origin: origin)
        // Before the sound places it: the clock prior.
        XCTAssertEqual(meeting.timelineTime(of: whiteboard)!, 64, accuracy: 0.001)
        // The sound places the phone's recording at 4.2 s with a little drift: the photo moves with it.
        phone.alignment = SourceAlignment(method: .audio, offset: 4.2, rate: 1.0005, confidence: 0.9, referenceTrackID: mic.id)
        phone.offset = 4.2
        meeting.tracks[1] = phone
        XCTAssertEqual(meeting.timelineTime(of: whiteboard)!, 4.2 + 1.0005 * 60, accuracy: 0.001)
        // A photo the phone took after its recording ended, by its own clock: read through the phone
        // recording's placement, so the phone's clock being ahead doesn't shift it.
        let after = MeetingPhoto(relativePath: "Originals/Photos/x.heic", fileName: "x.heic", sha256: "",
                                 capturedAt: phoneStart.addingTimeInterval(620), capturedAtSource: .camera, origin: origin)
        XCTAssertEqual(meeting.timelineTime(of: after)!, 4.2 + 1.0005 * 620, accuracy: 0.001)
        // The Mac's own photo at the same moment by its clock lands within the drift of the phone's.
        let macPhoto = MeetingPhoto(relativePath: "Originals/Photos/m.jpg", fileName: "m.jpg", sha256: "",
                                    capturedAt: macStart.addingTimeInterval(64.2), origin: PhotoOrigin(kind: PhotoOrigin.macKind))
        XCTAssertEqual(meeting.timelineTime(of: macPhoto)!, meeting.timelineTime(of: whiteboard)!, accuracy: 0.05)
    }

    func testPhotosTakenWhileThisMacRecordedIntoAnExistingTimelineMoveOntoItsRecording() {
        var meeting = Meeting(title: "Existing")
        let earlier = MeetingPhoto(relativePath: "Originals/Photos/e.jpg", fileName: "e.jpg", sha256: "", capturedAt: Date(), time: 10)
        let new = MeetingPhoto(relativePath: "Originals/Photos/n.jpg", fileName: "n.jpg", sha256: "", capturedAt: Date(), time: 70)
        meeting.photos = [earlier, new]
        let lead = track(offset: 5)
        meeting.movePhotos(onto: lead, except: [earlier.id])
        XCTAssertNil(meeting.photo(earlier.id)?.trackID)
        XCTAssertEqual(meeting.photo(new.id)?.trackID, lead.id)
        XCTAssertEqual(meeting.photo(new.id)?.time, 65)
    }

    // MARK: Merging

    func testConcurrentPhotoEditsMergeFieldByFieldAndNoPhotoIsLost() {
        var base = Meeting(title: "Offsite")
        let shared = MeetingPhoto(relativePath: "Originals/Photos/s.jpg", fileName: "s.jpg", sha256: String(repeating: "c", count: 64), capturedAt: Date())
        base.addPhoto(shared)
        var mac = base, phone = base
        let fromPhone = MeetingPhoto(relativePath: "Originals/Photos/p.jpg", fileName: "p.jpg", sha256: String(repeating: "d", count: 64), capturedAt: Date())
        phone.addPhoto(fromPhone)
        phone.setPhotoCaption(shared.id, caption: "Agenda")
        mac.applyPhotoAnalyses([shared.id: PhotoAnalysis(caption: "Whiteboard", recognizedText: "Agenda", isInformative: true)])
        let merged = MeetingMerge.merge(base: base, local: mac, remote: phone).meeting
        XCTAssertEqual(Set(merged.photos?.map(\.id) ?? []), [shared.id, fromPhone.id])
        XCTAssertEqual(merged.photo(shared.id)?.caption, "Agenda")
        XCTAssertEqual(merged.photo(shared.id)?.analysis?.caption, "Whiteboard")
        // A deletion on one device and a caption on the other both stand.
        var left = merged, right = merged
        left.removePhoto(fromPhone.id); right.setPhotoCaption(fromPhone.id, caption: "Lunch")
        let again = MeetingMerge.merge(base: merged, local: left, remote: right).meeting
        XCTAssertTrue(again.photo(fromPhone.id)?.isRemoved == true)
        XCTAssertEqual(again.photo(fromPhone.id)?.caption, "Lunch")
        // A copy that never had photos (an older Daybook) can't remove them.
        var older = merged; older.photos = nil
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: older, remote: merged).meeting.photos?.count, 2)
    }

    // MARK: Placement in the summary

    func testSimultaneousAnalysesConvergeInEitherMergeDirection() {
        var base = Meeting(title: "Board")
        let photo = MeetingPhoto(relativePath: "Originals/Photos/a.jpg", fileName: "a.jpg", sha256: "", capturedAt: Date())
        base.addPhoto(photo)
        var a = base, b = base
        let now = Date()
        a.applyPhotoAnalyses([photo.id: PhotoAnalysis(caption: "Board", createdAt: now)])
        b.applyPhotoAnalyses([photo.id: PhotoAnalysis(caption: "Slide", createdAt: now)])
        XCTAssertEqual(MeetingMerge.merge(base: base, local: a, remote: b).meeting.photos,
                       MeetingMerge.merge(base: base, local: b, remote: a).meeting.photos)
    }

    private func analysed(_ time: TimeInterval?, text: String? = nil, caption: String? = nil, informative: Bool = true, start: Date) -> MeetingPhoto {
        MeetingPhoto(relativePath: "Originals/Photos/\(UUID().uuidString).jpg", fileName: "p.jpg", sha256: "",
                     capturedAt: start.addingTimeInterval(time ?? -86_400), time: time,
                     analysis: PhotoAnalysis(caption: caption, recognizedText: text, labels: ["whiteboard"], sharpness: 0.8, isInformative: informative))
    }

    private func planningMeeting(start: Date) -> Meeting {
        let mic = track(startedAt: start)
        var meeting = Meeting(title: "Planning", date: start, tracks: [mic])
        meeting.unifiedTranscript = [
            TranscriptSegment(trackID: mic.id, start: 0, end: 40, text: "Let's review the launch budget and the marketing spend for spring."),
            TranscriptSegment(trackID: mic.id, start: 40, end: 120, text: "The budget spreadsheet shows marketing spend over by ten percent."),
            TranscriptSegment(trackID: mic.id, start: 300, end: 360, text: "Hiring: we need two designers and a recruiter before the summer."),
            TranscriptSegment(trackID: mic.id, start: 360, end: 420, text: "Designers interviews start next week, recruiter contract signed.")
        ]
        return meeting
    }

    func testPlacementKeepsValidChoicesDropsUninformativeAndFallsBackToTheClosestSectionInTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = planningMeeting(start: start)
        let slide = analysed(80, text: "Spring budget\nMarketing 110%\nEvents 90%", start: start)
        let hiringBoard = analysed(380, text: "Hiring plan: 2 designers, 1 recruiter", start: start)
        let blurry = analysed(90, caption: "Blurred", informative: false, start: start)
        let lunch = analysed(200, caption: "Sandwich", start: start)
        meeting.photos = [slide, hiringBoard, blurry, lunch]
        let candidates = PhotoPlacement.candidates(in: meeting)
        XCTAssertEqual(candidates.map(\.id), [slide.id, lunch.id, hiringBoard.id], "the blurred photo is never offered")
        XCTAssertEqual(candidates.map(\.label), ["P1", "P2", "P3"])
        // The model put the slide under Budget, named the blurred photo too, used the slide twice, and
        // left the hiring board out.
        let proposed = MeetingSummary(overview: "Budget and hiring.", sections: [
            SummarySection(heading: "Budget", body: "Marketing spend is ten percent over budget.", photoIDs: [slide.id, blurry.id]),
            SummarySection(heading: "Hiring", body: "Two designers and a recruiter before summer.", photoIDs: [slide.id])
        ])
        let arranged = PhotoPlacement.arrange(proposed, in: meeting)
        XCTAssertEqual(arranged.sections[0].photoIDs, [slide.id])
        // The hiring board shows words and was taken during the hiring talk: the fallback places it there.
        XCTAssertEqual(arranged.sections[1].photoIDs, [hiringBoard.id])
        XCTAssertFalse(arranged.sections.contains { $0.photoIDs?.contains(lunch.id) == true }, "an unrelated photo stays out")
    }

    func testTheFallbackUsesSectionOrderWhenNoSectionSharesWords() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = planningMeeting(start: start)
        let late = analysed(400, text: "Q4 OKR draft one two three", start: start)
        meeting.photos = [late]
        let proposed = MeetingSummary(overview: "Two topics.", sections: [
            SummarySection(heading: "First", body: "Alpha."), SummarySection(heading: "Second", body: "Omega.")
        ])
        let arranged = PhotoPlacement.arrange(proposed, in: meeting)
        XCTAssertNil(arranged.sections[0].photoIDs)
        XCTAssertEqual(arranged.sections[1].photoIDs, [late.id], "the later half of the conversation")
        // Taken out of the summary by the person: never placed again.
        meeting.setPhotoHiddenFromSummary(late.id, hidden: true)
        XCTAssertNil(PhotoPlacement.arrange(proposed, in: meeting).sections[1].photoIDs)
    }

    func testEvidenceListsEachPhotoWithItsTimeAndText() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meeting = planningMeeting(start: start)
        meeting.photos = [analysed(80, text: "Spring budget", caption: "Whiteboard with the budget", start: start)]
        let evidence = PhotoPlacement.evidence(PhotoPlacement.candidates(in: meeting))
        XCTAssertEqual(evidence, "[P1]; taken at 01:20; shows: Whiteboard with the budget; text in the photo: Spring budget")
    }
}
