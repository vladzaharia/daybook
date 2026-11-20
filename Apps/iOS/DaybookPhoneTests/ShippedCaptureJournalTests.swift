import AVFoundation
import DaybookCore
import XCTest
@testable import DaybookPhone

/// Capture journals exactly as shipped versions wrote them (Fixtures/README.md) still load, keep
/// every field, and recover, so a renamed, retyped, or newly required field can't strand a
/// recording a killed app left behind before an update.
@MainActor
final class ShippedCaptureJournalTests: XCTestCase {
    private func fixture(_ version: String, _ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures/\(version)"),
                      "Fixtures/\(version)/\(name) is in the test bundle")
    }

    /// A capture folder holding the v0.2.2 journal.
    private func v022Folder() throws -> URL {
        let folder = try temporaryDirectory().appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try fixture("v0.2.2", "phone-capture.json"), to: PhoneCaptureJournal.url(in: folder))
        return folder
    }

    func testAV022JournalLoadsWithEveryFieldAndNoPhotos() throws {
        let folder = try v022Folder()
        let journal = try PhoneCaptureJournal.load(from: folder)
        let created = Date(timeIntervalSince1970: 1_792_850_000)
        XCTAssertEqual(journal.schemaVersion, 1)
        XCTAssertEqual(journal.id, UUID(uuidString: "6B1F2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        XCTAssertEqual(journal.title, "Synthetic standup")
        XCTAssertEqual(journal.createdAt, created)
        XCTAssertEqual(journal.startedAt, created.addingTimeInterval(0.25))
        XCTAssertEqual(journal.hostTimeSeconds, 1_000)
        XCTAssertEqual(journal.continuousTimeSeconds, 1_005)
        XCTAssertEqual(journal.sampleRate, 48_000)
        XCTAssertEqual(journal.bitRate, 64_000)
        XCTAssertEqual(journal.state, .recording)
        XCTAssertNil(journal.endedAt)
        XCTAssertNil(journal.finalFile)
        XCTAssertNil(journal.photos, "written before photos")

        XCTAssertEqual(journal.segments.map(\.fileName), ["segment-000.m4a", "segment-001.m4a"])
        XCTAssertEqual(journal.segments.map(\.index), [0, 1])
        XCTAssertEqual(journal.segments.map(\.startOffset), [0, 5])
        XCTAssertEqual(journal.segments.map(\.frameCount), [144_000, 96_000])
        XCTAssertEqual(journal.segments.map(\.closed), [true, false])
        XCTAssertEqual(journal.segments.map(\.firstSampleHostTime), [1_000, 1_005])
        XCTAssertEqual(journal.segments[0].clockAnchors, [ClockAnchor(frame: 0, hostTime: 1_000), ClockAnchor(frame: 48_000, hostTime: 1_001),
                                                          ClockAnchor(frame: 96_000, hostTime: 1_002)])
        XCTAssertEqual(journal.segments[1].clockAnchors.count, 2)
        XCTAssertNil(journal.segments[0].notes)

        XCTAssertEqual(journal.interruptions, [CaptureInterruption(began: 3, ended: 5, reason: "A call or another app interrupted the recording.",
                                                                   resumed: true)])
        XCTAssertEqual(journal.routes, [CaptureRouteEvent(time: 0, input: AudioInputRoute(name: "iPhone Microphone", portType: "MicrophoneBuiltIn"),
                                                          reason: "start")])
        XCTAssertEqual(journal.warnings, [])
        XCTAssertEqual(journal.notes, "Agenda\nShip on Friday")
        XCTAssertEqual(journal.timedNotes.map(\.text), ["Agenda", "Ship on Friday"])
        XCTAssertEqual(journal.timedNotes.map(\.time), [nil, 5.5])
        XCTAssertEqual(journal.timedNotes.map(\.id.uuidString), ["11111111-2222-4333-8444-555555555555", "66666666-7777-4888-8999-AAAAAAAAAAAA"])
        XCTAssertEqual(journal.highlights.map(\.time), [2, 6])
        XCTAssertEqual(journal.highlights.map(\.text), ["", "Decision"])
        XCTAssertEqual(journal.highlights.map(\.id.uuidString), ["BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF", "12345678-9ABC-4DEF-8123-456789ABCDEF"])
        XCTAssertEqual(journal.highlights.map(\.trackID), [nil, nil])
    }

    /// Today's code writes it back with every key v0.2.2 wrote, and reads that back unchanged.
    func testAV022JournalRoundTripsWithItsKeys() throws {
        let folder = try v022Folder()
        let journal = try PhoneCaptureJournal.load(from: folder)
        let rewritten = try JournalCoding.encoder().encode(journal)
        XCTAssertEqual(try JournalCoding.decoder().decode(PhoneCaptureJournal.self, from: rewritten), journal)

        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: PhoneCaptureJournal.url(in: folder))) as? [String: Any])
        let today = try XCTUnwrap(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        XCTAssertEqual(Set(original.keys).subtracting(today.keys), [], "no key v0.2.2 wrote is dropped or renamed")
        for key in ["segments", "interruptions", "routes", "timedNotes", "highlights"] {
            let old = try XCTUnwrap(original[key] as? [[String: Any]]), new = try XCTUnwrap(today[key] as? [[String: Any]])
            XCTAssertEqual(old.count, new.count, key)
            for (before, after) in zip(old, new) {
                XCTAssertEqual(Set(before.keys).subtracting(after.keys), [], "\(key): no key dropped or renamed")
            }
        }
        // Dates stay in milliseconds since 1970.
        XCTAssertEqual(today["createdAt"] as? Double, 1_792_850_000_000)
        XCTAssertEqual(today["startedAt"] as? Double, 1_792_850_000_250)
    }

    /// The folder v0.2.2 left when it was killed after the interruption recovers with today's code:
    /// both parts in order, the gap silent, notes and bookmarks kept, no photos.
    func testAV022CaptureFolderLeftByACrashRecovers() async throws {
        let folder = try v022Folder()
        let scratch = try temporaryDirectory()
        XCTAssertEqual(try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 3, frequency: 440), 144_000)
        let second = try await CaptureFiles.inProgressSegment(seconds: 4, frequency: 660, in: scratch)
        try second.write(to: folder.appendingPathComponent("segment-001.m4a"))
        let secondFrames = try CaptureFiles.readableFrames(second, scratch: scratch)
        XCTAssertGreaterThanOrEqual(secondFrames, 48_000)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertTrue(recording.recovered)
        XCTAssertEqual(recording.id, UUID(uuidString: "6B1F2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        XCTAssertEqual(recording.title, "Synthetic standup")
        XCTAssertEqual(recording.startedAt, Date(timeIntervalSince1970: 1_792_850_000.25))
        XCTAssertEqual(recording.hostTimeSeconds, 1_000)
        XCTAssertEqual(recording.notes, "Agenda\nShip on Friday")
        XCTAssertEqual(recording.timedNotes.map(\.time), [nil, 5.5])
        XCTAssertEqual(recording.highlights.map(\.time), [2, 6])
        XCTAssertEqual(recording.photos, [])
        let notes = recording.capture.notes ?? []
        XCTAssertTrue(notes.contains("Recorded with iPhone Microphone."), "\(notes)")
        XCTAssertTrue(notes.contains("Paused 0:03–0:05 (A call or another app interrupted the recording.); the gap is silent."), "\(notes)")
        XCTAssertTrue(recording.warnings.contains { $0.contains("Daybook quit while recording") })

        let after = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(after.state, .stopped)
        // The parts' packets are copied: the second lands within one AAC frame of where it was recorded.
        XCTAssertEqual(Double(after.finalFile?.frameCount ?? 0), Double(5 * 48_000 + secondFrames), accuracy: Double(RecordingAssembler.packetFrames))
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.frequency(0.3..<2.7), 440, accuracy: 3)
        XCTAssertLessThan(audio.rms(3.2..<4.8), 0.003, "the interruption is silence")
        XCTAssertEqual(audio.frequency(5.3..<(audio.duration - 0.2)), 660, accuracy: 3)
    }

    // MARK: Notebook pages

    func testBehaviorJournalWithoutPagesLoads() throws {
        let folder = try v022Folder()
        let journal = try PhoneCaptureJournal.load(from: folder)
        XCTAssertNil(journal.pages, "written before pages")
        XCTAssertNil(journal.pageClock)
        // Written back without either key: a journal that never held a page is the bytes it was.
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JournalCoding.encoder().encode(journal)) as? [String: Any])
        XCTAssertNil(rewritten["pages"])
        XCTAssertNil(rewritten["pageClock"])
    }

    func testBehaviorJournalWithPagesRoundTrips() throws {
        let folder = try v022Folder()
        var journal = try PhoneCaptureJournal.load(from: folder)
        let at = Date(timeIntervalSince1970: 1_792_850_100)
        let id = UUID()
        var made = NotebookPage(id: id, order: 2, origin: PhotoOrigin(kind: "daybook.iphone", serial: "INSTALL-1", name: "Alex's iPhone"), now: at)
        made.corrections = [PassageCorrection(passageID: UUID(), strokeDigest: "abc", text: "Budget review", editedAt: at)]
        let loadedID = UUID()
        var loaded = NotebookPage(id: loadedID, order: 1, now: at.addingTimeInterval(-60))
        loaded.drawing = PageDrawing(relativePath: PageDrawing.relativePath(page: loadedID, sha256: String(repeating: "a", count: 64)),
                                     sha256: String(repeating: "a", count: 64), byteCount: 900, strokeCount: 4, editedAt: at.addingTimeInterval(-30), contentVersion: 1)
        journal.pages = [CapturePage(page: made, drawingFile: CapturePage.fileName(for: id), drawingSHA256: String(repeating: "b", count: 64),
                                     strokeCount: 7, contentVersion: 1, committedAt: at, base: nil),
                         CapturePage(page: loaded, base: loaded)]
        journal.pageClock = [RecordingClockSample(at: at, elapsed: 4, running: true), RecordingClockSample(at: at.addingTimeInterval(9), elapsed: 13, running: false)]
        try journal.write(to: folder)
        let back = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(back.pages, journal.pages)
        XCTAssertEqual(back.pageClock, journal.pageClock)
        XCTAssertEqual(back, journal)
        XCTAssertEqual(back.pages?[0].page.origin?.name, "Alex's iPhone")
        XCTAssertEqual(back.pages?[1].base, loaded, "the copy the recording loaded, for a three-way merge")
        XCTAssertEqual(CapturePage.fileName(for: id), "page-\(id.uuidString).pkdrawing")
    }
}
