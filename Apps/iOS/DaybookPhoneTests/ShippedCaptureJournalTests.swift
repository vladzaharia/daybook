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
        let second = try await CaptureFiles.inProgressSegment(seconds: 4, frequency: 660, in: scratch, test: self)
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
        XCTAssertEqual(after.finalFile?.frameCount, 5 * 48_000 + secondFrames)
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.frequency(0.3..<2.7), 440, accuracy: 3)
        XCTAssertLessThan(audio.rms(3.2..<4.8), 0.003, "the interruption is silence")
        XCTAssertEqual(audio.frequency(5.3..<(audio.duration - 0.2)), 660, accuracy: 3)
    }
}
