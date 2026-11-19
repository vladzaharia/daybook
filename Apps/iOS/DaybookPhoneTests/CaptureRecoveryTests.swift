import AVFoundation
import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// `PhoneRecorder.recover(in:)` on capture folders a killed app leaves behind, built deliberately
/// (`CaptureFiles`): a last fragment cut part-way through, a part the journal never heard of, and a
/// crash after an interruption. No microphone; synthetic tones.
@MainActor
final class CaptureRecoveryTests: XCTestCase {
    private let sampleRate = CaptureFiles.format.sampleRate
    /// One AAC frame, in seconds: how close a part copied into a joined file lands to its place.
    private var frame: TimeInterval { Double(RecordingAssembler.packetFrames) / sampleRate }
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
        let bytes = try await CaptureFiles.inProgressSegment(seconds: 5, frequency: 440, in: scratch)
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
        let orphan = try await CaptureFiles.inProgressSegment(seconds: 4, frequency: 660, in: scratch)
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
        // Their packets are copied: the adopted part lands within one AAC frame of straight after the first.
        XCTAssertEqual(Double(after.finalFile?.frameCount ?? 0), Double(first + orphanFrames), accuracy: Double(RecordingAssembler.packetFrames),
                       "both parts, with no gap between them")
        XCTAssertEqual(after.finalFile?.joined, true)
        XCTAssertTrue(recording.capture.notes?.contains("Placed after the previous part; its exact start wasn’t saved.") == true)
        XCTAssertTrue(recording.warnings.contains("Part of the recording couldn’t be read and was left out (segment-002.m4a)."),
                      "\(recording.warnings)")

        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.duration, 3 + Double(orphanFrames) / sampleRate, accuracy: frame)
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
        let second = try await CaptureFiles.inProgressSegment(seconds: 4, frequency: 660, in: scratch)
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
        XCTAssertEqual(Double(after.finalFile?.frameCount ?? 0), Double(5 * 48_000 + secondFrames), accuracy: Double(RecordingAssembler.packetFrames),
                       "3 s, a 2 s silent gap, then what reached the disk, within one AAC frame")
        XCTAssertEqual(recording.highlights.map(\.time), [2, 5.5])
        XCTAssertTrue(recording.capture.notes?.contains("Paused 0:03–0:05 (Phone call); the gap is silent.") == true,
                      "\(recording.capture.notes ?? [])")
        XCTAssertTrue(recording.warnings.contains { $0.contains("Daybook quit while recording") })

        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.duration, 5 + Double(secondFrames) / sampleRate, accuracy: frame)
        XCTAssertEqual(audio.frequency(0.3..<2.7), 440, accuracy: 3)
        XCTAssertEqual(audio.rms(0.3..<2.7), toneRMS, accuracy: 0.02)
        XCTAssertLessThan(audio.rms(3.2..<4.8), 0.003, "the interruption is silence")
        XCTAssertEqual(audio.frequency(5.3..<(audio.duration - 0.2)), 660, accuracy: 3)
        XCTAssertEqual(audio.rms(5.3..<(audio.duration - 0.2)), toneRMS, accuracy: 0.02)
    }

    /// Stop had ended the capture (every part closed, the journal saying `stopping`) and iOS ended Daybook while it was
    /// saving: the next launch saves it whole, and says it was interrupted while saving, never that it quit while
    /// recording. It ends when Stop ended it.
    func testARecordingInterruptedWhileSavingIsSavedWholeAndSaysSo() async throws {
        let folder = try newFolder("stopping")
        let first = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 3, frequency: 440)
        let second = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-001.m4a"), seconds: 2, frequency: 660)
        var journal = journal("Stopped from the Lock Screen", segments: [segment(0, at: 0, frames: first, closed: true),
                                                                         segment(1, at: 5, frames: second, closed: true)])
        journal.interruptions = [CaptureInterruption(began: 3, ended: 5, reason: "Phone call", resumed: true)]
        journal.highlights = [Highlight(time: 6)]
        journal.state = .stopping
        let ended = started.addingTimeInterval(7.2)
        journal.endedAt = ended
        try journal.write(to: folder)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertEqual(recording.recovery, .interruptedWhileSaving)
        XCTAssertTrue(recording.recovered)
        XCTAssertTrue(recording.warnings.contains(RecordingWords.savedAfterInterruptedSave), "\(recording.warnings)")
        XCTAssertFalse(recording.warnings.contains { $0.contains("quit while recording") })
        XCTAssertEqual(recording.endedAt, ended, "when Stop ended it")
        XCTAssertEqual(recording.duration, 7, accuracy: frame)
        XCTAssertEqual(recording.highlights.map(\.time), [6])
        let after = try PhoneCaptureJournal.load(from: folder)
        XCTAssertEqual(after.state, .stopped)
        XCTAssertEqual(after.finalFile?.joined, true)
        XCTAssertEqual(PhoneAppModel.recovered(.interruptedWhileSaving), "Saved a recording Daybook was interrupted while saving.")
        XCTAssertEqual(PhoneAppModel.recovered(.quitWhileRecording), "Recovered a recording Daybook was making when it quit.")

        // Recovering again (filing failed the first time) reuses the file and says it once.
        let again = try await PhoneRecorder.recover(in: folder)
        XCTAssertNil(again.recovery, "already saved: nothing more to say")
        XCTAssertEqual(again.warnings.filter { $0 == RecordingWords.savedAfterInterruptedSave }.count, 1)
    }

    /// What a locked iPhone can't open (its journal, a part, a lone part already moved into place) is never a recording
    /// with nothing in it: recovery says it's locked, so the folder is kept for the unlock. Files made unreadable
    /// stand in for a locked iPhone, which the simulator doesn't have.
    func testWhatCantBeOpenedIsLockedNeverNothingRecorded() async throws {
        func unreadable(_ url: URL) throws { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
        func readable(_ url: URL) throws { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        func expectLocked(_ folder: URL, _ what: String) async {
            do {
                _ = try await PhoneRecorder.recover(in: folder)
                XCTFail("recovered \(what)")
            } catch {
                XCTAssertEqual(error as? PhoneRecorderError, .locked, what)
            }
        }

        // The journal.
        let folder = try newFolder("journal")
        let frames = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 1, frequency: 440)
        var stopped = journal("Locked journal", segments: [segment(0, at: 0, frames: frames, closed: true)])
        stopped.state = .stopping
        try stopped.write(to: folder)
        try unreadable(PhoneCaptureJournal.url(in: folder))
        await expectLocked(folder, "an unreadable journal")
        try readable(PhoneCaptureJournal.url(in: folder))

        // A part.
        try unreadable(folder.appendingPathComponent("segment-000.m4a"))
        await expectLocked(folder, "an unreadable part")
        XCTAssertNil(try PhoneCaptureJournal.load(from: folder).finalFile, "nothing joined")
        try readable(folder.appendingPathComponent("segment-000.m4a"))

        // A lone part moved into place before Daybook was ended, the journal not yet saying so.
        let moved = try newFolder("moved")
        let output = moved.appendingPathComponent(PhoneCaptureJournal.finalFileName)
        let movedFrames = try CaptureFiles.writeClosedSegment(to: output, seconds: 1, frequency: 440)
        try journal("Moved", segments: [segment(0, at: 0, frames: movedFrames, closed: true)]).write(to: moved)
        try unreadable(output)
        await expectLocked(moved, "an unreadable joined file")
        try readable(output)
        let recovered = try await PhoneRecorder.recover(in: moved)
        XCTAssertEqual(recovered.duration, 1, accuracy: frame, "once it can be read, it's all there")
    }

    // MARK: Notebook pages

    private func strokes(_ tag: String) -> Data { Data((tag + String(repeating: "ink", count: 40)).utf8) }

    private func reading(of data: Data, page: UUID, words: String, key: String, time: TimeInterval?) -> PageReading {
        let passage = NotebookPassage(id: NotebookPassage.id(page: page, firstStroke: key), kind: .writing, x: 0, y: 0, width: 10, height: 10, strokeCount: 3,
                                      strokeDigest: PassageGrouping.digest(of: [key]), start: started.addingTimeInterval(time ?? 0),
                                      end: started.addingTimeInterval((time ?? 0) + 2), time: time, words: words)
        return PageReading(drawingSHA256: AudioDigest.sha256(data: data), passages: [passage], readAt: started,
                           settings: ProcessingSettings(modelID: "test", parameters: ["grouping": String(PassageGrouping.version)]))
    }

    /// A capture folder a crash left, with one closed part and the notebook's journal and staged strokes.
    private func crashedFolder(pages: [CapturePage], files: [UUID: Data], clock: [RecordingClockSample]) throws -> URL {
        let folder = try newFolder("notebook")
        let frames = try CaptureFiles.writeClosedSegment(to: folder.appendingPathComponent("segment-000.m4a"), seconds: 2, frequency: 440)
        var crashed = journal("Notebook", segments: [segment(0, at: 0, frames: frames, closed: true)])
        crashed.pages = pages
        crashed.pageClock = clock
        try crashed.write(to: folder)
        for (id, data) in files { try data.write(to: folder.appendingPathComponent(CapturePage.fileName(for: id))) }
        return folder
    }

    func testBehaviorRecoveredRecordingFilesPages() async throws {
        let committedID = UUID(), draftID = UUID(), emptyID = UUID()
        let committed = strokes("committed"), draft = strokes("draft-newer-than-the-journal")
        var written = NotebookPage(id: committedID, order: 1, origin: PhotoOrigin(kind: "daybook.iphone", serial: "INSTALL-1", name: "Alex's iPhone"), now: started)
        written.reading = reading(of: committed, page: committedID, words: "Budget", key: "1-3-1-1", time: 1.5)
        let pages = [CapturePage(page: written, drawingFile: CapturePage.fileName(for: committedID), drawingSHA256: AudioDigest.sha256(data: committed),
                                 strokeCount: 6, contentVersion: 1, committedAt: started.addingTimeInterval(2)),
                     // Written on and never committed: only the draft file says so.
                     CapturePage(page: NotebookPage(id: draftID, order: 2, now: started)),
                     // Never written on: not filed.
                     CapturePage(page: NotebookPage(id: emptyID, order: 3, now: started))]
        let clock = [RecordingClockSample(at: started, elapsed: 0, running: true), RecordingClockSample(at: started.addingTimeInterval(1), elapsed: 1, running: true)]
        let folder = try crashedFolder(pages: pages, files: [committedID: committed, draftID: draft], clock: clock)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertTrue(recording.recovered)
        XCTAssertEqual(recording.pages.map(\.page.id), [committedID, draftID, emptyID])
        XCTAssertEqual(recording.pageClock, clock)

        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        let filed = try await library.file(recording)
        XCTAssertEqual(filed.visiblePages.map(\.id), [committedID, draftID], "the page nothing was written on isn't filed")
        let page = try XCTUnwrap(filed.page(committedID))
        let drawing = try XCTUnwrap(page.drawing)
        XCTAssertEqual(drawing.sha256, AudioDigest.sha256(data: committed))
        XCTAssertEqual(drawing.strokeCount, 6)
        XCTAssertEqual(drawing.device, "Alex's iPhone")
        let stored = try await library.controller.pageDrawingURL(for: drawing, in: filed.id)
        XCTAssertEqual(try Data(contentsOf: stored), committed, "stored in the conversation's folder")
        XCTAssertTrue(page.isReadingCurrent, "the reading is of the committed strokes")
        let late = try XCTUnwrap(filed.page(draftID)?.drawing)
        let lateURL = try await library.controller.pageDrawingURL(for: late, in: filed.id)
        XCTAssertEqual(try Data(contentsOf: lateURL), draft, "the draft the crash left is filed")
        XCTAssertTrue(filed.page(draftID)?.needsReading == true)
        // The passage is on the phone's track, seconds into it, and the clock samples are kept with the track.
        let track = try XCTUnwrap(filed.tracks.first)
        let passage = try XCTUnwrap(page.passages.first)
        XCTAssertEqual(passage.trackID, track.id)
        XCTAssertEqual(passage.time, 1.5)
        XCTAssertEqual(track.clockSamples, clock)
        XCTAssertEqual(filed.timelineTime(of: passage, on: page), 1.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the staging folder goes once the pages are on disk")
        XCTAssertTrue(filed.revisions.contains { $0.kind == .page(committedID) })
    }

    func testBehaviorFilingShiftsPhoneLedTimesAndAnchorsMacLedToTrack() async throws {
        let id = UUID()
        var page = NotebookPage(id: id, order: 1, now: started)
        let data = strokes("ink")
        let earlier = NotebookPassage(id: NotebookPassage.id(page: id, firstStroke: "0-1-1-1"), kind: .writing, x: 0, y: 0, width: 5, height: 5, strokeCount: 1,
                                      strokeDigest: "d0", start: started, end: started, trackID: UUID(), time: 100, words: "from before")
        let new = reading(of: data, page: id, words: "now", key: "1-3-1-1", time: 12).passages[0]
        page.reading = PageReading(drawingSHA256: AudioDigest.sha256(data: data), passages: [earlier, new], readAt: started)
        page.erased = [ErasedStroke(key: "9-9-9-9", madeAt: started, erasedAt: started, time: 7)]
        var base = page
        base.reading?.passages = [earlier]
        base.erased = nil
        let track = UUID()

        // With audio, on the phone's track as photos are, whoever leads: the seconds are the recording's, and follow it.
        let onTrack = PhoneLibrary.placed(page, base: base, placing: .track(track))
        XCTAssertEqual(onTrack.reading?.passages.map(\.trackID), [earlier.trackID, track])
        XCTAssertEqual(onTrack.reading?.passages.map(\.time), [100, 12], "what the conversation had keeps its own place")
        XCTAssertEqual(onTrack.erased?.first?.trackID, track)
        XCTAssertEqual(onTrack.erased?.first?.time, 7)
        // Without audio (filed as notes), on the timeline: its own, as the phone started it, or moved to where it started on a Mac's.
        let led = PhoneLibrary.placed(page, base: base, placing: .timeline(shift: 0))
        XCTAssertEqual(led.reading?.passages.map(\.time), [100, 12])
        XCTAssertNil(led.reading?.passages[1].trackID)
        let joined = PhoneLibrary.placed(page, base: base, placing: .timeline(shift: 30))
        XCTAssertEqual(joined.reading?.passages.map(\.time), [100, 42], "moved by where this iPhone started on the Mac's timeline")
        XCTAssertEqual(joined.erased?.first?.time, 37)
        XCTAssertNil(joined.reading?.passages[1].trackID)
        // Never had a first sample: its seconds mean nothing.
        let unplaced = PhoneLibrary.placed(page, base: base, placing: .timeline(shift: nil))
        XCTAssertNil(unplaced.reading?.passages[1].time)
        XCTAssertEqual(unplaced.reading?.passages[0].time, 100)
        // A passage with no time (no recording clock) stays without.
        var bare = page
        bare.reading?.passages[1].time = nil
        XCTAssertNil(PhoneLibrary.placed(bare, base: base, placing: .track(track)).reading?.passages[1].trackID)

        // Filed as notes through `UnrecordedCapture`: a Mac-led one is moved by where it started on the Mac's timeline.
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        for (name, role, expected) in [("phone", CaptureMultipoint.Role.phoneLed, 12.0), ("mac", .macLed, 42.0)] {
            let folder = try newFolder(name)
            var capture = journal(name, segments: [])
            capture.multipoint = CaptureMultipoint(role: role, leadMacID: role == .macLed ? UUID() : nil, leadStartedAt: started.addingTimeInterval(-30),
                                                   timelineStart: started.addingTimeInterval(-30), leadClockOffset: 0, title: "Standup", date: started.addingTimeInterval(-30))
            var notes = NotebookPage(id: UUID(), order: 1, now: started)
            notes.reading = reading(of: data, page: notes.id, words: "ink", key: "1-3-1-1", time: 12)
            capture.pages = [CapturePage(page: notes, drawingFile: CapturePage.fileName(for: notes.id), drawingSHA256: AudioDigest.sha256(data: data), strokeCount: 3,
                                         contentVersion: 1, committedAt: started)]
            try capture.write(to: folder)
            try data.write(to: folder.appendingPathComponent(CapturePage.fileName(for: notes.id)))
            XCTAssertTrue(UnrecordedCapture.hasContent(capture), "pages are content: a recording with only them isn't discarded")
            let filedID = try await UnrecordedCapture.file(capture, in: folder, library: library)
            let filed = try XCTUnwrap(library.controller.meeting(filedID))
            let passage = try XCTUnwrap(filed.page(notes.id)?.passages.first)
            XCTAssertNil(passage.trackID, name)
            XCTAssertEqual(passage.time, expected, name)
        }
    }

    func testBehaviorFilingEditOfLoadedPageMergesWithBase() async throws {
        // A conversation with a written page; the iPhone records into it while the person edits it elsewhere.
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        try await library.reload()
        let conversation = UUID()
        let pageID = UUID()
        let old = strokes("old")
        library.controller.add(Meeting(id: conversation, title: "Weekly", date: started, status: .draft))
        library.controller.addPage(NotebookPage(id: pageID, order: 1, now: started), to: conversation)
        let first = try await library.controller.commitPageDrawing(old, page: pageID, in: conversation, strokeCount: 3, contentVersion: 1, device: "Alex's iPhone", now: started)
        library.controller.applyPageReading(reading(of: old, page: pageID, words: "first draft", key: "1-3-1-1", time: nil), to: pageID, in: conversation)
        let page = try XCTUnwrap(library.controller.meeting(conversation)?.page(pageID))

        // The recording loads it, writes more strokes, and reads them.
        let rig = RecorderRig()
        let folder = library.stagingURL.appendingPathComponent(conversation.uuidString)
        try await rig.recorder.start(in: folder, id: conversation, title: "Weekly")
        rig.recorder.loadPages(from: library.controller.meeting(conversation))
        rig.pump(3)
        let newer = strokes("old and new")
        let sha = try XCTUnwrap(rig.recorder.commitPage(pageID, data: newer, strokeCount: 5, contentVersion: 1))
        rig.recorder.applyPageReading(pageID, reading(of: newer, page: pageID, words: "second draft", key: "2-3-1-1", time: 3))
        rig.pump(1)
        let recording = try await rig.stop()

        // Meanwhile elsewhere the person corrected the first passage and added a page.
        let passage = try XCTUnwrap(page.passages.first)
        library.controller.correctPassage(pageID: pageID, passageID: passage.id, text: "first draft, fixed", in: conversation)
        let other = NotebookPage(id: UUID(), order: 2, now: started)
        library.controller.addPage(other, to: conversation)

        let filed = try await library.file(recording)
        let merged = try XCTUnwrap(filed.page(pageID))
        XCTAssertEqual(merged.drawing?.sha256, sha, "the strokes written during the recording are the page's")
        XCTAssertGreaterThan(merged.drawing?.editedAt ?? .distantPast, first.editedAt, "stamped after the drawing it was loaded with")
        XCTAssertEqual(merged.corrections?.first?.text, "first draft, fixed", "what was changed elsewhere meanwhile survives")
        XCTAssertTrue(merged.isReadingCurrent)
        XCTAssertEqual(merged.passages.first?.words, "second draft")
        let track = try XCTUnwrap(filed.tracks.first)
        XCTAssertEqual(merged.passages.first?.trackID, track.id, "the new reading follows the track")
        XCTAssertEqual(merged.passages.first?.time, 3)
        XCTAssertEqual(Set(filed.visiblePages.map(\.id)), [pageID, other.id], "the page added elsewhere meanwhile is still there")
        XCTAssertNil(merged.setAside, "one side changed the strokes, so nothing is set aside")
        let stored = try await library.controller.pageDrawingURL(for: try XCTUnwrap(merged.drawing), in: conversation)
        XCTAssertEqual(try Data(contentsOf: stored), newer)
    }
}
