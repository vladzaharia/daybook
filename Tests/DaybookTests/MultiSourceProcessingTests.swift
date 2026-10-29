import DaybookCore
import DaybookDevices
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Recordings that arrive after the fact find their conversation, and each new source enhances it:
/// only the new recording is transcribed, it's lined up and fused, the person's work survives,
/// Version History records it, and the summary is written again. Temporary libraries, synthetic
/// audio, a fake inference engine, and a stubbed `AudioAligner`; no models, no microphone.
@MainActor
final class MultiSourceProcessingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let phrases = ["We should ship the calendar feature tomorrow", "Jordan will review the database migration next",
                           "The onboarding experiment improved activation rates substantially", "Let us schedule another review for Monday",
                           "Priya owns the pricing page copy this sprint"]

    private func rig(models: Bool = true) async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: models)
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    /// The phrases every 30 s from `origin` in a recording's own time, dropping any before it began.
    private func lines(from origin: Double, extra: [(Double, String)] = []) -> [(Double, String)] {
        phrases.enumerated().map { (origin + Double($0.offset) * 30, $0.element) }.filter { $0.0 >= 0 } + extra
    }

    private func digest(_ url: URL) throws -> String { try AudioDigest.sha256(fileURL: url) }

    /// A conversation recorded on this Mac at `start`, transcribed and summarized.
    private func processedCall(_ rig: MultiSourceRig, at date: Date? = nil) async throws -> (UUID, URL) {
        let mic = try rig.audio("mic-\(UUID().uuidString.prefix(4)).wav", frequency: 220, seconds: 0.5)
        try rig.inference.script(mic, lines(from: 0))
        let id = try await rig.macConversation("Design review", at: date ?? start, seconds: 1_800, audio: mic)
        rig.state.enqueue(id)
        try await rig.processed()
        XCTAssertEqual(rig.meeting(id)?.summary?.overview, "Summary 1")
        return (id, mic)
    }

    // MARK: Finding the conversation

    func testRecordingThatOverlapsAndSoundsTheSameJoinsWhereTheAlignerPlacesIt() async throws {
        let rig = try await rig(models: false)
        let mic = try rig.audio("mic.wav", frequency: 220)
        let call = try await rig.macConversation("Design review", at: start, seconds: 1_800, audio: mic)
        let priors = Priors()
        rig.state.sources.alignAudio = { _, _, expected, radius in
            priors.add(expected, radius)
            return AudioAlignment(offset: 7.25, rate: 1.0002, confidence: 0.9)
        }
        let file = try rig.audio("soundcore.wav", frequency: 523)
        let joined = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(7)),
                                                          attachTo: nil, source: .soundcore)
        XCTAssertEqual(joined, call)
        XCTAssertEqual(rig.state.meetings.count, 1)
        XCTAssertEqual(priors.values.first?.expected, 7, "The recorders' clocks are the aligner's prior")
        XCTAssertEqual(priors.values.first?.radius, rig.state.sources.policy.clockSearchRadius)

        let meeting = try XCTUnwrap(rig.meeting(call))
        let track = try XCTUnwrap(meeting.tracks.first { $0.source == .soundcore })
        let alignment = try XCTUnwrap(track.alignment)
        XCTAssertEqual(alignment.method, .audio)
        XCTAssertEqual(alignment.offset, 7.25)
        XCTAssertEqual(alignment.rate, 1.0002)
        XCTAssertEqual(alignment.confidence, 0.9)
        XCTAssertEqual(alignment.referenceTrackID, meeting.tracks.first { $0.source == .microphone }?.id)
        XCTAssertEqual(alignment.clockOffset, 7)
        XCTAssertEqual(track.offset, 7.25, "The aligner's result is the recording's timing")
        XCTAssertEqual(track.startedAt, start.addingTimeInterval(7))
        XCTAssertTrue(meeting.revisions.contains { $0.newValue == "Added Soundcore Work recording" })
        XCTAssertTrue(rig.state.awaitingModels.contains(call), "Models missing: it waits, with its placement kept")

        // With models, the fused transcript uses that placement, drift included.
        rig.state.installedModels = [rig.state.transcriptionModel, rig.state.summaryModel, rig.state.processingPreferences.speakerModelID]
        try rig.inference.script(mic, lines(from: 0))
        try rig.inference.script(file, [(100, "Only the recorder caught this aside about hiring")])
        rig.state.enqueue(call)
        try await rig.processed()
        let aside = try XCTUnwrap(rig.meeting(call)?.unifiedTranscript.first { $0.text.contains("aside about hiring") })
        XCTAssertEqual(aside.start, 7.25 + 100 * 1.0002, accuracy: 0.0001)
        XCTAssertEqual(rig.state.sourceTimingLine(track, in: try XCTUnwrap(rig.meeting(call))), "Lined up by sound · starts 0:07")
    }

    func testTheInspectorSaysWhereARecordingCameFromAndHowItLinesUpOnce() async throws {
        let rig = try await rig(models: false)
        let state = rig.state
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/mic.wav", fileName: "mic.wav", offset: 0)
        let alone = Meeting(title: "Alone", tracks: [mic])
        XCTAssertEqual(state.recordingName(mic, in: alone), "Microphone")
        XCTAssertEqual(state.sourceLine(mic, in: alone), "This Mac", "Its only recording: no timing, and the microphone said once")

        let soundcore = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "S1", recordingID: "1")
        let aligned = RecordingTrack(source: .soundcore, relativePath: "Originals/a.wav", fileName: "a.wav", device: soundcore,
                                     alignment: SourceAlignment(method: .audio, offset: 12.4, rate: 1.0002, confidence: 0.93))
        let together = RecordingTrack(source: .imported, relativePath: "Originals/b.wav", fileName: "Interview.m4a",
                                      device: DeviceRecordingIdentity(kind: OtherRecorderIntegration.id, recordingID: "file:b"),
                                      alignment: SourceAlignment(method: .transcript, offset: 0.3))
        var several = Meeting(title: "Several", tracks: [mic, aligned, together])
        several.alignmentReports = [TrackAlignment(trackID: mic.id, method: .reference)]
        XCTAssertEqual(state.sourceLine(mic, in: several), "This Mac · The main recording")
        XCTAssertEqual(state.recordingName(aligned, in: several), "Soundcore Work")
        XCTAssertEqual(state.sourceLine(aligned, in: several), "Lined up by sound · starts 0:12", "Its name says the recorder; no confidence or drift")
        XCTAssertEqual(state.sourceLine(together, in: several), "Other Recorder · Lined up by shared phrases", "A start of 0:00 isn't said")

        several.tracks[1].alignment = SourceAlignment(method: .unaligned)
        XCTAssertEqual(state.sourceTimingLine(several.tracks[1], in: several), "Couldn’t line up")
    }

    func testRecordingOverlappingTwoConversationsBecomesASuggestionUntilConfirmed() async throws {
        let rig = try await rig(models: false)
        // Short synthetic recordings stand in for long ones: 1.5 s and 1 s of overlap.
        let first = try await rig.macConversation("Standup", at: start, seconds: 2.5, audio: try rig.audio("a.wav", frequency: 220))
        let second = try await rig.macConversation("Planning", at: start.addingTimeInterval(2), seconds: 3, audio: try rig.audio("b.wav", frequency: 330))
        rig.state.sources.alignAudio = { _, _, _, _ in XCTFail("Ambiguous by time: the person decides"); return nil }
        let file = try rig.audio("soundcore.wav", frequency: 523, seconds: 2)
        let separate = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(1)),
                                                            attachTo: nil, source: .soundcore)
        XCTAssertFalse([first, second].contains(separate), "It gets its own conversation for now")
        let suggestion = try XCTUnwrap(rig.meeting(separate)?.sourceSuggestions?.first)
        XCTAssertEqual(suggestion.candidateMeetingIDs, [first, second], "Most overlap first")
        XCTAssertEqual(suggestion.reason, .severalConversations)
        XCTAssertEqual(suggestion.trackID, rig.meeting(separate)?.tracks.first?.id)
        XCTAssertEqual(suggestion.clockOffsets?[second] ?? 0, -1, accuracy: 0.001)

        // Bookmarks made on it while it was separate: one while playing it, one on its timeline.
        rig.state.addPlaybackHighlight(separate, trackID: suggestion.trackID, seconds: 0.5)
        rig.state.update(separate) { $0.highlights.append(Highlight(time: 1.25)) }

        let confirmed = await rig.state.confirmSourceSuggestion(suggestion.id, in: separate, into: first)
        XCTAssertTrue(confirmed)
        let joined = try XCTUnwrap(rig.meeting(first)?.tracks.first { $0.source == .soundcore })
        XCTAssertEqual(rig.meeting(first)?.highlights.filter { $0.trackID == joined.id }.map(\.time).sorted(), [0.5, 1.25],
                       "Its bookmarks come with it")
        XCTAssertEqual(joined.device?.kind, SoundcoreWorkIntegration.id)
        XCTAssertEqual(joined.alignment?.method, .pending)
        XCTAssertEqual(joined.alignment?.clockOffset ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(rig.meeting(first)?.revisions.contains { $0.newValue == "Added Soundcore Work recording" } == true)
        try await waitUntil("the separate conversation to move to the Trash") { rig.meeting(separate) == nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("Trash/\(separate.uuidString)").path),
                      "Its original stays restorable in the Trash")
        XCTAssertNil(rig.meeting(second)?.tracks.first { $0.source == .soundcore })
    }

    func testAConversationBeingRecordedNowCanBeSuggestedAndTheSuggestionDismissed() async throws {
        let rig = try await rig(models: false)
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 10).rounded(.down))
        let earlier = try await rig.macConversation("Standup", at: base, seconds: 6, audio: try rig.audio("a.wav", frequency: 220))
        let live = rig.state.newMeeting(title: "Recording now", date: base.addingTimeInterval(4))
        rig.state.recordingID = live
        rig.state.recordingStartedAt = base.addingTimeInterval(4)
        defer { rig.state.recordingID = nil; rig.state.recordingStartedAt = nil }
        let file = try rig.audio("soundcore.wav", frequency: 523, seconds: 2)
        let separate = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(base.addingTimeInterval(3)),
                                                            attachTo: nil, source: .soundcore)
        XCTAssertFalse([earlier, live].contains(separate))
        let suggestion = try XCTUnwrap(rig.meeting(separate)?.sourceSuggestions?.first)
        XCTAssertEqual(Set(suggestion.candidateMeetingIDs), [earlier, live], "The conversation being recorded now is a candidate")
        rig.state.dismissSourceSuggestion(suggestion.id, in: separate)
        XCTAssertNil(rig.meeting(separate)?.sourceSuggestions)
        XCTAssertNotNil(rig.meeting(separate), "Keep Separate leaves it as its own conversation")
        XCTAssertEqual(rig.meeting(live)?.tracks.count, 0)
    }

    func testRecordingThatOverlapsNothingGetsItsOwnConversation() async throws {
        let rig = try await rig(models: false)
        let call = try await rig.macConversation("Design review", at: start, seconds: 1_800, audio: try rig.audio("mic.wav", frequency: 220))
        rig.state.sources.alignAudio = { _, _, _, _ in XCTFail("Nothing overlaps, so there is nothing to compare"); return nil }
        let file = try rig.audio("soundcore.wav", frequency: 523)
        let id = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(-86_400)),
                                                      attachTo: nil, source: .soundcore)
        XCTAssertNotEqual(id, call)
        let meeting = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(meeting.title.hasPrefix("Soundcore Work at"), true)
        XCTAssertNil(meeting.sourceSuggestions)
        XCTAssertNil(meeting.tracks.first?.alignment, "Its own conversation's first recording sets its timeline, as before")
        XCTAssertEqual(meeting.tracks.first?.startedAt, start.addingTimeInterval(-86_400))
    }

    /// The sound gives no verdict (today's aligner); the transcript confirms the match afterwards and
    /// the recording moves in with its transcript, so nothing is transcribed or summarized twice.
    func testOverlapTheSoundCannotConfirmIsSettledByTheTranscript() async throws {
        let rig = try await rig()
        let (call, mic) = try await processedCall(rig)
        let file = try rig.audio("soundcore.wav", frequency: 523)
        try rig.inference.script(file, lines(from: -8, extra: [(130, "Only the recorder caught this closing remark")]))
        let separate = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(8)),
                                                            attachTo: nil, source: .soundcore)
        XCTAssertNotEqual(separate, call)
        XCTAssertEqual(rig.meeting(separate)?.sourceSuggestions?.first?.reason, .checkingTranscript)
        try await waitUntil("the recording to move into the call") { rig.meeting(call)?.tracks.count == 2 }
        try await rig.processed()
        try await waitUntil("the separate conversation to move to the Trash") { rig.meeting(separate) == nil }

        let meeting = try XCTUnwrap(rig.meeting(call))
        let track = try XCTUnwrap(meeting.tracks.first { $0.source == .soundcore })
        XCTAssertEqual(track.alignment?.method, .transcript)
        XCTAssertEqual(track.alignment?.offset ?? 0, 8, accuracy: 0.01)
        XCTAssertEqual(meeting.transcripts.filter { $0.trackID == track.id }.count, 1, "Its transcript came with it")
        XCTAssertEqual(rig.inference.transcribed, [try digest(mic), try digest(file)], "Each recording transcribed once")
        XCTAssertEqual(rig.inference.summarized.count, 2, "The call summarized again; the separate conversation never")
        XCTAssertEqual(meeting.summary?.overview, "Summary 2")
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text.contains("closing remark") }?.start ?? 0, 138, accuracy: 0.01)
        XCTAssertTrue(meeting.revisions.contains { $0.newValue == "Added Soundcore Work recording" })
    }

    /// A multipoint recorder's file can be imported before this Mac's own recording is stored. It is
    /// placed by the clocks meanwhile and lined up by sound once there is something to compare with.
    func testRecorderFileArrivingBeforeTheMacRecordingIsLinedUpOnceItIsIn() async throws {
        let rig = try await rig()
        let calls = Priors()
        rig.state.sources.alignAudio = { _, reference, expected, radius in
            calls.add(expected, radius, reference.lastPathComponent)
            return AudioAlignment(offset: 2.4, confidence: 0.9)
        }
        let id = rig.state.newMeeting(title: "Zoom call", date: start)
        var link = CompanionRecording(deviceID: "recorder", deviceKind: SoundcoreWorkIntegration.id, deviceSerial: "FAKE1",
                                      deviceName: "Soundcore Work", macStartedAt: start, state: .stopped, startedByDaybook: true)
        link.recorderStartedAt = start.addingTimeInterval(2)
        rig.state.update(id) { $0.companions = [link]; $0.date = self.start }
        let file = try rig.audio("soundcore.wav", frequency: 523)
        try rig.inference.script(file, lines(from: 0))
        let joined = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(2)),
                                                          attachTo: nil, source: .soundcore)
        XCTAssertEqual(joined, id)
        try await rig.processed()
        var recorder = try XCTUnwrap(rig.meeting(id)?.tracks.first)
        XCTAssertTrue(calls.values.isEmpty, "Nothing to compare with yet")
        XCTAssertEqual(recorder.alignment?.method, .clock, "Placed by the clocks meanwhile")
        XCTAssertEqual(recorder.offset, 2)
        XCTAssertNil(recorder.alignment?.audioChecked)

        // This Mac's microphone recording is stored (as ingestCapture stores it), then processed.
        let mic = try rig.audio("microphone.wav", frequency: 220)
        try rig.inference.script(mic, lines(from: 2.4))
        let store = try MeetingStore(rootURL: rig.root)
        await rig.state.flush()
        let imported = try await store.importAudio(from: mic, into: try XCTUnwrap(rig.meeting(id)), source: .microphone, offset: 0)
        rig.state.update(id) { meeting in
            for track in imported.tracks where !meeting.tracks.contains(where: { $0.id == track.id }) {
                var captured = track; captured.createdAt = self.start; meeting.tracks.append(captured)
            }
        }
        rig.state.enqueue(id)
        try await rig.processed()
        recorder = try XCTUnwrap(rig.meeting(id)?.tracks.first { $0.id == recorder.id })
        XCTAssertEqual(calls.values.count, 1)
        XCTAssertEqual(calls.values.first?.expected, 2, "The clocks' estimate is the prior")
        XCTAssertEqual(recorder.alignment?.method, .audio)
        XCTAssertEqual(recorder.offset, 2.4)
        XCTAssertEqual(rig.meeting(id)?.unifiedTranscript.filter { $0.text == phrases[1] }.count, 1, "Both recordings of a phrase become one")
    }

    // MARK: Enhancement

    func testNewSourceIsTranscribedAloneAndThePersonsWorkSurvives() async throws {
        let rig = try await rig()
        let (call, mic) = try await processedCall(rig)
        let speaker = try XCTUnwrap(rig.meeting(call)?.speakers.first?.id)
        let passage = try XCTUnwrap(rig.meeting(call)?.unifiedTranscript.first { $0.text == phrases[1] })
        rig.state.update(call) { meeting in
            meeting.renameSpeaker(id: speaker, name: "Dana")
            meeting.correctSegment(id: passage.id, text: "Jordan will review the Postgres migration next")
            meeting.timedNotes = [TimedNote(time: 31, text: "Migration owner"), TimedNote(text: "Agenda")]
            meeting.highlights.append(Highlight(time: 61, text: "Activation"))
        }
        let before = try XCTUnwrap(rig.meeting(call))

        rig.state.sources.alignAudio = { _, _, _, _ in AudioAlignment(offset: 4, confidence: 0.9) }
        let file = try rig.audio("soundcore.wav", frequency: 523)
        try rig.inference.script(file, lines(from: -4, extra: [(136, "Only the recorder caught this closing remark")]))
        let joined = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(4)),
                                                          attachTo: nil, source: .soundcore)
        XCTAssertEqual(joined, call)
        try await rig.processed()

        let meeting = try XCTUnwrap(rig.meeting(call))
        XCTAssertEqual(rig.inference.transcribed, [try digest(mic), try digest(file)], "Only the new recording is transcribed")
        XCTAssertTrue(meeting.revisions.contains { $0.field.hasPrefix("source:") && $0.newValue == "Added Soundcore Work recording" })
        XCTAssertEqual(meeting.summary?.overview, "Summary 2", "Summarized again")
        let earlier = meeting.revisions.filter { $0.field == "summary" }
        XCTAssertEqual(earlier.count, 2)
        XCTAssertTrue(earlier.last?.oldValue.contains("Summary 1") == true, "The earlier summary stays in Version History")
        let evidence = try XCTUnwrap(rig.inference.summarized.last)
        XCTAssertTrue(evidence.contains("Dana: Jordan will review the Postgres migration next"), evidence)
        XCTAssertTrue(evidence.contains("closing remark"), "Summaries use every source")

        let kept = try XCTUnwrap(meeting.unifiedTranscript.first { $0.id == passage.id })
        XCTAssertEqual(kept.text, "Jordan will review the Postgres migration next")
        XCTAssertEqual(kept.speakerID, speaker)
        XCTAssertEqual(meeting.speakers.first { $0.id == speaker }?.name, "Dana")
        XCTAssertEqual(meeting.timedNotes, before.timedNotes)
        XCTAssertEqual(meeting.highlights.map(meeting.alignedTime), before.highlights.map(before.alignedTime))
        XCTAssertNil(meeting.correctionTransferIssues)
        XCTAssertEqual(meeting.unifiedTranscript.filter { $0.text == phrases[3] }.count, 1, "One passage for both recordings of it")
    }

    func testPauseAndCancelWhileAddingASource() async throws {
        let rig = try await rig()
        let (call, _) = try await processedCall(rig)
        rig.state.sources.alignAudio = { _, _, _, _ in AudioAlignment(offset: 4, confidence: 0.9) }
        let file = try rig.audio("soundcore.wav", frequency: 523)
        try rig.inference.script(file, lines(from: -4))
        try rig.inference.block(file)
        _ = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(start.addingTimeInterval(4)), attachTo: nil, source: .soundcore)
        try await waitUntil("the new recording to be transcribing") { rig.inference.isWaiting(on: file) }
        XCTAssertEqual(rig.state.sourceActivity(call), "Adding Soundcore Work recording…")

        rig.state.pauseProcessing(call)
        try await waitUntil("the pause") { rig.state.processingID == nil }
        var meeting = try XCTUnwrap(rig.meeting(call))
        let track = try XCTUnwrap(meeting.tracks.first { $0.source == .soundcore })
        XCTAssertTrue(rig.state.pausedIDs.contains(call))
        XCTAssertEqual(meeting.status, .ready, "Its earlier summary stays")
        XCTAssertEqual(meeting.summary?.overview, "Summary 1")
        XCTAssertFalse(meeting.transcripts.contains { $0.trackID == track.id })
        XCTAssertEqual(track.alignment?.method, .audio, "The placement survives the pause")
        XCTAssertNil(rig.state.sourceActivity(call))

        try rig.inference.unblock(file)
        rig.state.enqueue(call, mode: rig.state.defaultProcessingMode(for: meeting))
        try await rig.processed()
        meeting = try XCTUnwrap(rig.meeting(call))
        XCTAssertTrue(meeting.transcripts.contains { $0.trackID == track.id })
        XCTAssertEqual(meeting.summary?.overview, "Summary 2")

        // Cancel stops the conversation adding a source and empties the queue behind it.
        let second = try rig.audio("soundcore-2.wav", frequency: 587)
        try rig.inference.block(second)
        _ = try await rig.state.importFromDevice(second, identity: MultiSourceRig.soundcore(start.addingTimeInterval(60)), attachTo: nil, source: .soundcore)
        let other = try rig.audio("other.wav", frequency: 698)
        try await rig.state.importFiles([other], source: .imported, attachTo: nil)
        try await waitUntil("the second recording to be transcribing") { rig.inference.isWaiting(on: second) }
        XCTAssertEqual(rig.state.queuedIDs.count, 1)
        rig.state.cancelProcessing()
        try await waitUntil("the cancel") { rig.state.processingID == nil }
        XCTAssertTrue(rig.state.queuedIDs.isEmpty)
        XCTAssertTrue(rig.state.pausedIDs.contains(call))
        XCTAssertEqual(rig.meeting(call)?.tracks.filter { $0.source == .soundcore }.count, 2, "Cancelling keeps the recording")
        XCTAssertFalse(rig.inference.transcribed.contains(try digest(other)))
    }

    // MARK: The other direction

    /// This Mac records into a conversation a recorder started: its recording joins the recorder's
    /// timeline, and what the person marked meanwhile follows it.
    func testMacRecordingIntoARecorderConversationJoinsItsTimeline() async throws {
        let rig = try await rig()
        let recorderFile = try rig.audio("soundcore.wav", frequency: 523)
        try rig.inference.script(recorderFile, lines(from: 120))
        let workshop = try await rig.state.importFromDevice(recorderFile, identity: MultiSourceRig.soundcore(start), attachTo: nil, source: .soundcore)
        try await rig.processed()
        XCTAssertTrue(rig.state.canRecordInto(workshop))

        // What startRecording(into:) does: this Mac starts 119.65 s into the recorder's recording.
        let macStart = start.addingTimeInterval(119.65)
        rig.state.prepareSourceCapture(workshop)
        rig.state.recordingID = workshop
        rig.state.recordingStartedAt = macStart
        rig.state.update(workshop) { $0.status = .recording; $0.date = macStart }
        rig.state.recordingDidStart(workshop)
        XCTAssertEqual(rig.meeting(workshop)?.date, start, "The conversation keeps its date")
        let note = TimedNote(time: 10, text: "Ask about the migration")
        rig.state.update(workshop) { $0.timedNotes = [note]; $0.highlights.append(Highlight(time: 12, text: "Pricing")) }
        rig.state.recordingWillFinish(workshop, at: macStart.addingTimeInterval(300))
        rig.state.recordingID = nil

        // What ingestCapture does with the microphone file.
        let mic = try rig.audio("microphone.wav", frequency: 220)
        try rig.inference.script(mic, lines(from: 0.4))
        await rig.state.flush()
        let store = try MeetingStore(rootURL: rig.root)
        let imported = try await store.importAudio(from: mic, into: try XCTUnwrap(rig.meeting(workshop)), source: .microphone, offset: 0.05)
        rig.state.update(workshop) { meeting in
            for track in imported.tracks where !meeting.tracks.contains(where: { $0.id == track.id }) {
                var captured = track
                captured.createdAt = macStart.addingTimeInterval(0.05)
                captured.duration = 300
                meeting.tracks.append(captured)
            }
            meeting.date = macStart
            meeting.status = .imported
        }
        rig.state.sourcesAfterCapture(workshop, startedAt: macStart, captureID: UUID())

        var meeting = try XCTUnwrap(rig.meeting(workshop))
        let macTrack = try XCTUnwrap(meeting.tracks.first { $0.source == .microphone })
        XCTAssertEqual(meeting.date, start)
        XCTAssertEqual(macTrack.alignment?.method, .pending)
        XCTAssertEqual(macTrack.alignment?.clockOffset ?? 0, 119.7, accuracy: 0.0001)
        XCTAssertEqual(macTrack.alignment?.heldNoteIDs, [note.id])
        XCTAssertNil(macTrack.offset)
        XCTAssertEqual(meeting.highlights.first?.trackID, macTrack.id, "The bookmark follows this Mac's recording")
        XCTAssertEqual(meeting.highlights.first?.time ?? 0, 11.95, accuracy: 0.0001)
        XCTAssertTrue(meeting.revisions.contains { $0.newValue == "Added recording from this Mac" })

        let references = Priors()
        rig.state.sources.alignAudio = { _, reference, expected, _ in
            references.add(expected, 0, reference.lastPathComponent)
            return AudioAlignment(offset: 119.6, confidence: 0.88)
        }
        rig.state.enqueue(workshop)
        try await rig.processed()
        meeting = try XCTUnwrap(rig.meeting(workshop))
        let placed = try XCTUnwrap(meeting.tracks.first { $0.id == macTrack.id })
        XCTAssertEqual(references.values.first?.name, meeting.tracks.first { $0.source == .soundcore }.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent },
                       "Lined up against the recorder's recording")
        XCTAssertEqual(references.values.first?.expected ?? 0, 119.7, accuracy: 0.0001)
        XCTAssertEqual(placed.alignment?.method, .audio)
        XCTAssertEqual(placed.offset, 119.6)
        XCTAssertEqual(meeting.timedNotes?.first?.time ?? 0, 129.55, accuracy: 0.0001, "The note moved onto the conversation's timeline")
        XCTAssertEqual(meeting.alignedTime(for: try XCTUnwrap(meeting.highlights.first)) ?? 0, 131.55, accuracy: 0.0001)
        XCTAssertEqual(meeting.alignmentReports.first { $0.method == .reference }?.trackID, meeting.tracks.first { $0.source == .soundcore }?.id)
        XCTAssertEqual(meeting.unifiedTranscript.filter { $0.text == phrases[2] }.count, 1)
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text == phrases[2] }?.start ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(rig.inference.transcribed, [try digest(recorderFile), try digest(mic)])
    }
}

/// What the aligner was asked, from its background thread.
private final class Priors: @unchecked Sendable {
    struct Value { var expected: TimeInterval?; var radius: TimeInterval; var name: String }
    private let lock = NSLock()
    private var stored: [Value] = []
    func add(_ expected: TimeInterval?, _ radius: TimeInterval, _ name: String = "") { lock.withLock { stored.append(Value(expected: expected, radius: radius, name: name)) } }
    var values: [Value] { lock.withLock { stored } }
}
