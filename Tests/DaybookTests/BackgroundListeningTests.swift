import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Recordings transcribed before Daybook listened for music and TV are listened to on the Mac when
/// it's idle: Apple's sound classifier on a synthetic recording (speech from `say`, then a band),
/// the analysis kept on the recording, and the conversation fused again without transcribing,
/// keeping what the person corrected and named, the summary, and Version History.
@MainActor
final class BackgroundListeningTests: XCTestCase {
    /// The real classifier; transcribing would be a failure.
    private final class Listener: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _listened = 0
        var listened: Int { lock.withLock { _listened } }
        let hears: Bool
        init(hears: Bool = true) { self.hears = hears }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            XCTFail("Nothing is transcribed")
            return RecognitionResult(segments: [], language: "en", duration: 0)
        }
        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }
        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            XCTFail("Nothing is summarized")
            return GeneratedMeetingNotes(summary: MeetingSummary(overview: ""), suggestedTerms: [], rawResponse: "", warnings: [])
        }
        func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? {
            lock.withLock { _listened += 1 }
            return hears ? try SoundClassifier.analyze(url: url) : nil
        }
    }

    /// 36 s: a person for 10 s, then the band alone (a TV's closing music), with the passages a
    /// recognizer would write: what the person said, and words over the music.
    private func earlierConversation(_ rig: MultiSourceRig) async throws -> UUID {
        guard let voice = try SyntheticAudio.speech("Okay, so let's go over the launch plan for next week. Priya will send the checklist on Friday.",
                                                    voice: "Samantha", in: rig.root) else { throw XCTSkip("The Samantha voice isn't available to `say` here.") }
        var mix = SyntheticAudio.silence(36)
        SyntheticAudio.add(SyntheticAudio.level(voice, 0), into: &mix, at: 0, seconds: 10)
        SyntheticAudio.add(SyntheticAudio.level(SyntheticAudio.music(seconds: 24), 0), into: &mix, at: 12)
        let url = rig.root.appendingPathComponent("earlier.wav")
        try SyntheticAudio.write(SyntheticAudio.limited(mix), to: url)
        let id = try await rig.macConversation("Earlier", at: Date(timeIntervalSinceNow: -86_400), seconds: 36, audio: url)
        let run = UUID().uuidString
        rig.state.update(id) { meeting in
            let track = meeting.tracks[0].id
            meeting.transcripts = [TrackTranscript(trackID: track, segments: [
                TranscriptSegment(trackID: track, start: 0.3, end: 9.5, text: "Okay, so let's go over the launch plan for next week.", speakerID: "\(run):A"),
                TranscriptSegment(trackID: track, start: 13, end: 23, text: "Thank you for watching.", speakerID: "\(run):B"),
                TranscriptSegment(trackID: track, start: 25, end: 35, text: "Stay tuned.", speakerID: "\(run):B"),
            ])]
            meeting.speakers = [Speaker(id: "\(run):A", name: "Speaker 1", sourceTrackID: track), Speaker(id: "\(run):B", name: "Speaker 2", sourceTrackID: track)]
            XCTAssertNil(meeting.tracks[0].backgroundAudio, "Transcribed before Daybook listened")
        }
        await rig.state.realign(id)
        XCTAssertEqual(rig.meeting(id)?.unifiedTranscript.count, 3)
        return id
    }

    func testAnEarlierRecordingIsListenedToOnceAndFusedAgainKeepingWhatThePersonDid() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let listener = Listener()
        rig.state.sources.inference = listener
        rig.state.backgroundListeningDelay = .zero
        let id = try await earlierConversation(rig)
        // What the person did: a corrected passage (over the music), a named speaker, a summary.
        let stay = try XCTUnwrap(rig.meeting(id)?.unifiedTranscript.first { $0.text == "Stay tuned." })
        rig.state.update(id) { $0.correctSegment(id: stay.id, text: "Stay tuned, she said.") }
        let person = try XCTUnwrap(rig.meeting(id)?.speakers.first { $0.name == "Speaker 1" })
        rig.state.library.renameSpeaker(person.id, to: "Priya", in: id)
        rig.state.update(id) { $0.setSummary(MeetingSummary(overview: "The launch plan.")) }
        let before = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(before.recordingsAwaitingBackgroundAudio.map(\.id), [before.tracks[0].id])

        rig.state.listenToEarlierRecordingsWhenIdle()
        try await waitUntil("the recording to be listened to", timeout: 60, state: {
            "listened \(listener.listened), idle \(rig.state.mayListenToEarlierRecordings), analysis \(rig.meeting(id)?.tracks.map { $0.backgroundAudio?.frameCount ?? -1 } ?? []), "
                + "passages \(rig.meeting(id)?.unifiedTranscript.map(\.text) ?? [])"
        }) {
            rig.meeting(id)?.backgroundPassages != nil && !rig.state.isListeningToEarlierRecordings
        }
        let after = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(listener.listened, 1)
        XCTAssertEqual(after.tracks[0].backgroundAudio?.classifier, SoundClassifier.classifier, "Kept on the recording")
        XCTAssertTrue(after.recordingsAwaitingBackgroundAudio.isEmpty)
        XCTAssertEqual(after.unifiedTranscript.map(\.text), ["Okay, so let's go over the launch plan for next week.", "Stay tuned, she said."],
                       "The music is left out; the passage the person corrected stays, corrected")
        XCTAssertEqual(after.backgroundPassages?.map(\.text), ["Thank you for watching."])
        XCTAssertEqual(after.transcripts, before.transcripts, "Nothing transcribed again")
        XCTAssertEqual(after.revisions, before.revisions, "Version History is as it was")
        XCTAssertEqual(after.summary, before.summary)
        XCTAssertEqual(after.speakers.first { $0.id == person.id }?.name, "Priya")
        XCTAssertEqual(BackgroundAudioHook.line(after), "Left out 10 sec of music or TV")

        // Once: the next idle moment finds nothing to listen to.
        rig.state.listenToEarlierRecordingsWhenIdle()
        try await waitUntil("the pass to finish") { rig.state.backgroundListening == nil && !rig.state.isListeningToEarlierRecordings }
        XCTAssertEqual(listener.listened, 1)
    }

    func testListeningWaitsForOtherWorkAndARecordingThatCantBeClassifiedIsTriedOnce() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let deaf = Listener(hears: false)
        rig.state.sources.inference = deaf
        rig.state.backgroundListeningDelay = .zero
        let id = try await earlierConversation(rig)
        let fused = rig.meeting(id)?.unifiedTranscript

        // A download (any other work) runs first.
        rig.state.downloadingID = "whisper/base"
        rig.state.listenToEarlierRecordingsWhenIdle()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(deaf.listened, 0, "Nothing starts while other work runs")
        rig.state.downloadingID = nil
        rig.state.listenToEarlierRecordingsWhenIdle()
        try await waitUntil("the recording to be tried") { deaf.listened == 1 && rig.state.backgroundListening == nil }

        // The classifier couldn't run: nothing is left out or changed, and it isn't tried again this session.
        XCTAssertNil(rig.meeting(id)?.tracks[0].backgroundAudio)
        XCTAssertEqual(rig.meeting(id)?.unifiedTranscript, fused)
        rig.state.listenToEarlierRecordingsWhenIdle()
        try await waitUntil("the pass to finish") { rig.state.backgroundListening == nil && !rig.state.isListeningToEarlierRecordings }
        XCTAssertEqual(deaf.listened, 1)
    }
}
