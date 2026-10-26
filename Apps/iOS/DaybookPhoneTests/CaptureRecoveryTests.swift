import AVFoundation
import DaybookCore
import XCTest
@testable import DaybookPhone

/// `PhoneRecorder.recover(in:)` on capture folders a killed app leaves behind, built deliberately
/// (`CaptureFiles`): a last fragment cut part-way through, a part the journal never heard of, and a
/// crash after an interruption. No microphone; synthetic tones.
@MainActor
final class CaptureRecoveryTests: XCTestCase {
    private let sampleRate = CaptureFiles.format.sampleRate
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func journal(_ title: String, segments: [CaptureSegment]) -> PhoneCaptureJournal {
        var journal = PhoneCaptureJournal(id: UUID(), title: title, createdAt: started, format: CaptureFiles.format)
        journal.startedAt = started
        journal.hostTimeSeconds = 1_000
        journal.routes = [CaptureRouteEvent(time: 0, input: AudioInputRoute(name: "iPhone Microphone", portType: "MicrophoneBuiltIn"), reason: "start")]
        journal.segments = segments
        return journal
    }

    private func segment(_ index: Int, at offset: TimeInterval, frames: Int64, closed: Bool) -> CaptureSegment {
        CaptureSegment(index: index, fileName: String(format: "segment-%03d.m4a", index), startOffset: offset, frameCount: frames,
                       closed: closed, firstSampleHostTime: 1_000 + offset, clockAnchors: [ClockAnchor(frame: 0, hostTime: 1_000 + offset)],
                       notes: nil)
    }

    private func newFolder(_ name: String) throws -> URL {
        let folder = try temporaryDirectory().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Killed while the encoder wrote the last fragment: the file ends inside that fragment's index
    /// (its `moof`), or inside audio no index describes yet. Recovery keeps everything before the tear
    /// and files the recording.
    func testATornLastFragmentKeepsTheAudioBeforeTheTear() async throws {
        let scratch = try temporaryDirectory()
        let bytes = try await CaptureFiles.inProgressSegment(seconds: 5, frequency: 440, in: scratch, test: self)
        let boxes = CaptureFiles.boxes(bytes)
        let lastIndex = try XCTUnwrap(boxes.last { $0.type == "moof" && $0.end <= bytes.count })
        let beforeLast = try CaptureFiles.readableFrames(bytes.prefix(lastIndex.offset), scratch: scratch)
        let throughLast = try CaptureFiles.readableFrames(bytes.prefix(lastIndex.end), scratch: scratch)
        XCTAssertGreaterThanOrEqual(beforeLast, 48_000, "at least a second before the last fragment")
        XCTAssertGreaterThan(throughLast, beforeLast)

        let tears: [(name: String, cut: Int, keeps: Int64)] = [
            ("inside the last fragment's index", lastIndex.offset + lastIndex.size / 2, beforeLast),
            ("inside audio no index describes yet", lastIndex.end + max(1, (bytes.count - lastIndex.end) / 2), throughLast)
        ]
        for tear in tears {
            let folder = try newFolder("torn")
            try bytes.prefix(tear.cut).write(to: folder.appendingPathComponent("segment-000.m4a"))
            var journal = journal("Torn", segments: [segment(0, at: 0, frames: 5 * 48_000, closed: false)])
            journal.notes = "Before the crash"
            journal.timedNotes = [TimedNote(time: 0.5, text: "Before the crash")]
            journal.highlights = [Highlight(time: 1)]
            try journal.write(to: folder)
            let readable = try CaptureFiles.readableFrames(bytes.prefix(tear.cut), scratch: scratch)
            XCTAssertGreaterThanOrEqual(readable, tear.keeps, "\(tear.name): the torn file still opens up to the tear")

            let recording = try await PhoneRecorder.recover(in: folder)
            XCTAssertTrue(recording.recovered, tear.name)
            let after = try PhoneCaptureJournal.load(from: folder)
            XCTAssertEqual(after.state, .stopped, tear.name)
            XCTAssertEqual(after.finalFile?.frameCount, readable, "\(tear.name): everything readable before the tear is kept")
            XCTAssertEqual(recording.duration, Double(readable) / sampleRate, accuracy: 1e-9, tear.name)
            let audio = try DecodedAudio(url: recording.audioURL)
            XCTAssertEqual(audio.duration, recording.duration, accuracy: 0.001, tear.name)
            XCTAssertEqual(audio.rms(0.2..<(audio.duration - 0.2)), toneRMS, accuracy: 0.02, tear.name)
            XCTAssertEqual(audio.frequency(0.2..<(audio.duration - 0.2)), 440, accuracy: 3, tear.name)
            XCTAssertEqual(recording.notes, "Before the crash", tear.name)
            XCTAssertEqual(recording.timedNotes.map(\.time), [0.5], tear.name)
            XCTAssertEqual(recording.highlights.map(\.time), [1], tear.name)
            XCTAssertTrue(recording.warnings.contains { $0.contains("Daybook quit while recording") }, tear.name)
        }
    }

    /// The app died right after opening a new part (after a media-services reset, say), before the
    /// journal recorded it: the part is adopted, placed straight after the previous one, and said so.
    /// A part opened with nothing in it yet is left out without failing the recovery.
    func testAPartTheJournalNeverRecordedIsPlacedAfterThePreviousOne() async throws {
        let scratch = try temporaryDirectory()
        let folder = try newFolder("orphan")
        let first = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 3, frequency: 440)
        XCTAssertEqual(first, 144_000)
        let orphan = try await CaptureFiles.inProgressSegment(seconds: 4, frequency: 660, in: scratch, test: self)
        try orphan.write(to: folder.appendingPathComponent("segment-001.m4a"))
        let orphanFrames = try CaptureFiles.readableFrames(orphan, scratch: scratch)
        XCTAssertGreaterThanOrEqual(orphanFrames, 48_000)
        // Opened, and nothing written yet: the file type and an empty media box.
        let firstData = try XCTUnwrap(CaptureFiles.boxes(orphan).first { $0.type == "mdat" })
        try orphan.prefix(firstData.offset + 8).write(to: folder.appendingPathComponent("segment-002.m4a"))
        try journal("Orphan", segments: [segment(0, at: 0, frames: first, closed: true)]).write(to: folder)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertTrue(recording.recovered)
        let after = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(after.segments.map(\.fileName), ["segment-000.m4a", "segment-001.m4a", "segment-002.m4a"])
        let adopted = after.segments[1]
        XCTAssertEqual(adopted.index, 1)
        XCTAssertEqual(adopted.startOffset, 3, accuracy: 1e-9, "straight after the previous part")
        XCTAssertFalse(adopted.closed)
        XCTAssertEqual(adopted.notes, ["Placed after the previous part; its exact start wasn’t saved."])
        XCTAssertEqual(after.finalFile?.frameCount, first + orphanFrames, "both parts, with no gap between them")
        XCTAssertEqual(after.finalFile?.joined, true)
        XCTAssertTrue(recording.capture.notes?.contains("Placed after the previous part; its exact start wasn’t saved.") == true)
        XCTAssertTrue(recording.warnings.contains("Part of the recording couldn’t be read and was left out (segment-002.m4a)."),
                      "\(recording.warnings)")

        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.duration, 3 + Double(orphanFrames) / sampleRate, accuracy: 0.001)
        XCTAssertEqual(audio.frequency(0.3..<2.7), 440, accuracy: 3)
        XCTAssertEqual(audio.frequency(3.3..<(audio.duration - 0.2)), 660, accuracy: 3, "the adopted part follows the first")
        XCTAssertEqual(audio.rms(3.3..<(audio.duration - 0.2)), toneRMS, accuracy: 0.02)
    }

    /// An interruption closed the first part; recording resumed into a second part that was never
    /// closed. Both parts come back, in order, with the interruption as silence between them.
    func testACrashAfterAnInterruptionRecoversBothPartsInOrder() async throws {
        let scratch = try temporaryDirectory()
        let folder = try newFolder("interrupted")
        let first = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 3, frequency: 440)
        let second = try await CaptureFiles.inProgressSegment(seconds: 4, frequency: 660, in: scratch, test: self)
        try second.write(to: folder.appendingPathComponent("segment-001.m4a"))
        let secondFrames = try CaptureFiles.readableFrames(second, scratch: scratch)
        XCTAssertGreaterThanOrEqual(secondFrames, 48_000)
        // The journal counts frames handed to the encoder (4 s), more than reached the disk.
        var journal = journal("Interrupted", segments: [segment(0, at: 0, frames: first, closed: true),
                                                        segment(1, at: 5, frames: 4 * 48_000, closed: false)])
        journal.interruptions = [CaptureInterruption(began: 3, ended: 5, reason: "Phone call", resumed: true)]
        journal.highlights = [Highlight(time: 2), Highlight(time: 5.5)]
        try journal.write(to: folder)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertTrue(recording.recovered)
        let after = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(after.state, .stopped)
        XCTAssertEqual(after.finalFile?.joined, true)
        XCTAssertEqual(after.finalFile?.frameCount, 5 * 48_000 + secondFrames, "3 s, a 2 s silent gap, then what reached the disk")
        XCTAssertEqual(recording.highlights.map(\.time), [2, 5.5])
        XCTAssertTrue(recording.capture.notes?.contains("Paused 0:03–0:05 (Phone call); the gap is silent.") == true,
                      "\(recording.capture.notes ?? [])")
        XCTAssertTrue(recording.warnings.contains { $0.contains("Daybook quit while recording") })

        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.duration, 5 + Double(secondFrames) / sampleRate, accuracy: 0.001)
        XCTAssertEqual(audio.frequency(0.3..<2.7), 440, accuracy: 3)
        XCTAssertEqual(audio.rms(0.3..<2.7), toneRMS, accuracy: 0.02)
        XCTAssertLessThan(audio.rms(3.2..<4.8), 0.003, "the interruption is silence")
        XCTAssertEqual(audio.frequency(5.3..<(audio.duration - 0.2)), 660, accuracy: 3)
        XCTAssertEqual(audio.rms(5.3..<(audio.duration - 0.2)), toneRMS, accuracy: 0.02)
    }
}
