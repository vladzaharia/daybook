import Foundation
import XCTest
@testable import DaybookCore

/// Leaving background audio (a TV, radio, music) out of the transcript: the decision on synthetic
/// classifier frames, fusion keeping the passages recoverable, and the person including them again.
/// The real classifier on synthetic speech and music is measured in `SoundClassifierTests`.
final class BackgroundAudioTests: XCTestCase {
    /// An analysis with one frame per second from `(speech, music, audience, level)` tuples.
    private func analysis(_ frames: [(Double, Double, Double, Double)]) -> BackgroundAudioAnalysis {
        BackgroundAudioAnalysis(classifier: "test", hop: 1, window: 2, speech: frames.map(\.0), music: frames.map(\.1),
                                audience: frames.map(\.2), level: frames.map(\.3))
    }

    private func repeated(_ frame: (Double, Double, Double, Double), _ count: Int) -> [(Double, Double, Double, Double)] {
        Array(repeating: frame, count: count)
    }

    private let track = UUID()
    private func segment(_ start: Double, _ end: Double, _ text: String, _ speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(trackID: track, start: start, end: end, text: text, speakerID: speaker)
    }

    func testSoundTagsAreBackgroundEvenWithoutAnAnalysis() {
        for text in ["[Music]", "(upbeat music)", "[MUSIC PLAYING]", "♪ la la la ♪", "♪♪", "*music*", "[Applause]", "(theme song)"] {
            XCTAssertTrue(BackgroundAudio.isSoundTag(text), text)
        }
        for text in ["[laughter]", "I like that music", "[inaudible]", "(coughs)", "Music is on the agenda.", "", "[Music] Okay, let's start"] {
            XCTAssertFalse(BackgroundAudio.isSoundTag(text), text)
        }
        let tagged = segment(0, 3, "♪ ♪"), spoken = segment(3, 6, "Let's begin.")
        let verdict = BackgroundAudio.judge([tagged, spoken], analysis: nil)
        XCTAssertEqual(verdict.segments, [tagged.id: .music])
        XCTAssertEqual(BackgroundAudio.judge([segment(0, 2, "[Applause]")], analysis: nil).segments.values.first, .broadcast)
    }

    func testMusicWithoutSpeechIsLeftOutButAPersonOverQuietMusicStays() {
        // 0–10 s a person over quiet music; 10–20 s music alone; 20–30 s a person with no music.
        let frames = repeated((0.94, 0.5, 0, -24), 10) + repeated((0.05, 0.9, 0, -22), 10) + repeated((0.95, 0.1, 0, -20), 10)
        let overMusic = segment(0.5, 9.5, "So the plan is to ship on Friday.", "A")
        let lyrics = segment(10.5, 19, "Thank you for watching", "C")
        let plain = segment(20.5, 29, "And Priya sends the checklist.", "A")
        let verdict = BackgroundAudio.judge([overMusic, lyrics, plain], analysis: analysis(frames))
        XCTAssertEqual(verdict.segments, [lyrics.id: .music], "Only the stretch with music and no speech")
        XCTAssertEqual(verdict.speakers, ["C": .music], "The diarizer's cluster for the song isn't anyone's voice")

        // Applause rather than music is a broadcast.
        let applause = repeated((0.1, 0.1, 0.8, -20), 6)
        let clapping = segment(0.5, 5.5, "Yeah!")
        XCTAssertEqual(BackgroundAudio.judge([clapping], analysis: analysis(applause)).segments, [clapping.id: .broadcast])
    }

    func testABroadcastVoiceIsJudgedOnlyBesideTheConversation() {
        // 0–12 s the person (A) alone; 12–24 s a presenter (TV) over a music bed, quieter; 24–36 s A again.
        let frames = repeated((0.95, 0.1, 0, -20), 12) + repeated((0.8, 0.7, 0, -28), 12) + repeated((0.95, 0.12, 0, -20), 12)
        let a1 = segment(0.5, 11.5, "Let's look at the budget first.", "A")
        let tv1 = segment(12.5, 17.5, "Tonight on the evening news, heavy rain.", "TV")
        let tv2 = segment(18, 23.5, "Officials urge drivers to stay home.", "TV")
        let a2 = segment(24.5, 35.5, "Sorry, the TV's on. Where were we?", "A")
        let verdict = BackgroundAudio.judge([a1, tv1, tv2, a2], analysis: analysis(frames))
        XCTAssertEqual(verdict.speakers, ["TV": .broadcast])
        XCTAssertEqual(Set(verdict.segments.keys), [tv1.id, tv2.id])

        // A speaker the person named is never judged.
        XCTAssertTrue(BackgroundAudio.judge([a1, tv1, tv2, a2], analysis: analysis(frames), protectedSpeakers: ["TV"]).isEmpty)
        // With no one talking without music, there's no conversation to compare with: nothing is judged.
        XCTAssertTrue(BackgroundAudio.judge([tv1, tv2], analysis: analysis(frames)).isEmpty)
        // A voice over music as loud as the conversation is someone in the room talking over music.
        let near = repeated((0.95, 0.1, 0, -20), 12) + repeated((0.8, 0.7, 0, -19), 12) + repeated((0.95, 0.12, 0, -20), 12)
        XCTAssertTrue(BackgroundAudio.judge([a1, tv1, tv2, a2], analysis: analysis(near)).segments.isEmpty)
        // Without levels, distance can't agree: nothing is judged a broadcast.
        let unmeasured = BackgroundAudioAnalysis(classifier: "test", hop: 1, window: 2, speech: frames.map(\.0), music: frames.map(\.1),
                                                 audience: frames.map(\.2))
        XCTAssertTrue(BackgroundAudio.judge([a1, tv1, tv2, a2], analysis: unmeasured).isEmpty)
        // A second person talking over music at −12 dB (music comparable in under half the frames) stays.
        let mixed = repeated((0.95, 0.1, 0, -20), 12) + (0..<12).map { $0 % 5 < 2 ? (0.88, 0.74, 0.0, -20.0) : (0.92, 0.6, 0.0, -20.0) }
            + repeated((0.95, 0.12, 0, -20), 12)
        let b1 = segment(12.5, 17.5, "I think we can cut travel.", "B"), b2 = segment(18, 23.5, "And hold marketing flat.", "B")
        XCTAssertTrue(BackgroundAudio.judge([a1, b1, b2, a2], analysis: analysis(mixed)).isEmpty)
    }

    func testAnalysisFramesRoundTripCompactly() throws {
        let made = analysis([(1, 0.5, 0, -6), (0, 1, 0.25, -127), (0.2, 0.2, 0.2, 3)])
        XCTAssertEqual(made.frameCount, 3)
        XCTAssertEqual(made.frame(0).speech, 1); XCTAssertEqual(made.frame(0).music, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(made.frame(1).level, -127); XCTAssertEqual(made.frame(2).level, 0, "Levels are clamped to 0 dBFS")
        let decoded = try JSONDecoder().decode(BackgroundAudioAnalysis.self, from: JSONEncoder().encode(made))
        XCTAssertEqual(decoded, made)
        // Frames centred inside a span, or the nearest for a short one.
        XCTAssertEqual(made.frames(from: 0, to: 3).map(\.start), [0, 1, 2])
        XCTAssertEqual(made.frames(from: 1.1, to: 1.3).map(\.start), [0])
        XCTAssertTrue(made.frames(from: 30, to: 31).isEmpty)
        // A track whose analysis this version can't read still decodes.
        var track = RecordingTrack(relativePath: "a.caf", fileName: "a.caf")
        track.backgroundAudio = made
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        object["backgroundAudio"] = ["version": "two"]
        let older = try JSONDecoder().decode(RecordingTrack.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.backgroundAudio)
    }

    // MARK: Fusion

    private func meeting(frames: [(Double, Double, Double, Double)], segments: [TranscriptSegment]) -> Meeting {
        var recording = RecordingTrack(id: track, source: .microphone, relativePath: "a.caf", fileName: "a.caf", offset: 0, sha256: "a")
        recording.backgroundAudio = analysis(frames)
        return Meeting(tracks: [recording], transcripts: [TrackTranscript(trackID: track, segments: segments, modelID: "test")])
    }

    func testFusionLeavesBackgroundOutAndKeepsItRecoverable() throws {
        let frames = repeated((0.95, 0.1, 0, -20), 12) + repeated((0.8, 0.7, 0, -28), 12) + repeated((0.05, 0.9, 0, -22), 6)
            + repeated((0.95, 0.12, 0, -20), 12)
        let segments = [segment(0.5, 11.5, "Let's look at the budget first.", "A"),
                        segment(12.5, 17.5, "Tonight on the evening news, heavy rain.", "TV"),
                        segment(18, 23.5, "Officials urge drivers to stay home.", "TV"),
                        segment(24.5, 29.5, "Stay tuned for the weather.", "TV"),
                        segment(30.5, 41.5, "Sorry, the TV's on. Where were we?", "A")]
        var meeting = meeting(frames: frames, segments: segments)
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["Let's look at the budget first.", "Sorry, the TV's on. Where were we?"])
        XCTAssertEqual(meeting.backgroundPassages?.map(\.text), ["Tonight on the evening news, heavy rain.", "Officials urge drivers to stay home.",
                                                                 "Stay tuned for the weather."])
        XCTAssertEqual(meeting.backgroundDuration, 15.5, accuracy: 0.01)
        XCTAssertEqual(meeting.backgroundOnlySpeakerIDs, ["TV"], "The presenter isn't one of the people")
        XCTAssertEqual(meeting.transcripts[0].segments.count, 5, "The transcript run keeps every passage")

        // The person includes it: everything is back, and nothing is left out.
        meeting.includesBackgroundAudio = true
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        XCTAssertEqual(meeting.unifiedTranscript.count, 5)
        XCTAssertNil(meeting.backgroundPassages)
    }

    func testAPassageThePersonCorrectedIsNeverLeftOut() {
        // 0–10 s the person; 10–30 s music alone, with two passages a recognizer wrote over it.
        let frames = repeated((0.95, 0.1, 0, -20), 10) + repeated((0.05, 0.9, 0, -22), 20)
        let segments = [segment(0.5, 9.5, "Let's look at the budget first.", "A"), segment(10.5, 19, "Thank you for watching.", "B"),
                        segment(20.5, 29, "Stay tuned.", "B")]
        var meeting = meeting(frames: frames, segments: segments)
        meeting.includesBackgroundAudio = true
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        // Heard with the music included, the person corrected one of them; then left the music out.
        meeting.correctSegment(id: segments[2].id, text: "Stay tuned, she said.")
        meeting.includesBackgroundAudio = nil
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["Let's look at the budget first.", "Stay tuned, she said."])
        XCTAssertEqual(meeting.backgroundPassages?.map(\.text), ["Thank you for watching."])
        XCTAssertNil(meeting.correctionTransferIssues, "The correction still has its passage")
        XCTAssertTrue(meeting.unifiedTranscript.contains { $0.id == segments[2].id }, "So Version History can still put it back")
        // Judged directly, a corrected passage is protected like a named speaker.
        XCTAssertEqual(BackgroundAudio.judge(segments, analysis: analysis(frames), protectedSegments: [segments[1].id]).segments,
                       [segments[2].id: .music])
    }

    func testRecordingsTranscribedBeforeListeningAwaitAnAnalysis() {
        var meeting = meeting(frames: repeated((0.95, 0.1, 0, -20), 4), segments: [segment(0.5, 3, "Hello.")])
        XCTAssertTrue(meeting.recordingsAwaitingBackgroundAudio.isEmpty, "Analysed when it was transcribed")
        meeting.tracks[0].backgroundAudio = nil
        // Another recording not transcribed yet; a microphone transcribed through its echo-cancelled copy.
        let untranscribed = RecordingTrack(source: .soundcore, relativePath: "b.m4a", fileName: "b.m4a")
        let original = RecordingTrack(source: .microphone, relativePath: "m.caf", fileName: "m.caf")
        var derived = RecordingTrack(source: .microphone, relativePath: "m-clean.caf", fileName: "m-clean.caf")
        derived.derivedFrom = original.id
        meeting.tracks += [untranscribed, original, derived]
        meeting.transcripts += [TrackTranscript(trackID: original.id, segments: [], modelID: "old"),
                                TrackTranscript(trackID: derived.id, segments: [], modelID: "test")]
        XCTAssertEqual(meeting.recordingsAwaitingBackgroundAudio.map(\.id), [track, derived.id])
        var older = analysis(repeated((0.95, 0.1, 0, -20), 4))
        older.version = 0
        meeting.tracks[0].backgroundAudio = older
        XCTAssertEqual(meeting.recordingsAwaitingBackgroundAudio.map(\.id), [track, derived.id], "An older analysis is measured again")
    }

    func testAPassageAnotherRecordingHeardAsConversationStays() {
        // The microphone's passage is judged music; a second recording heard the same words with no music.
        let frames = repeated((0.05, 0.9, 0, -22), 12)
        var meeting = meeting(frames: frames, segments: [segment(0.5, 11, "we should move the launch to Friday then")])
        let other = UUID()
        meeting.tracks.append(RecordingTrack(id: other, source: .soundcore, relativePath: "b.m4a", fileName: "b.m4a", offset: 0, sha256: "b"))
        meeting.transcripts.append(TrackTranscript(trackID: other, segments: [
            TranscriptSegment(trackID: other, start: 0.5, end: 11, text: "we should move the launch to Friday then")], modelID: "test"))
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["we should move the launch to Friday then"])
        XCTAssertNil(meeting.backgroundPassages)
    }

    func testBookmarkContextLeavesBackgroundOut() {
        let frames = repeated((0.05, 0.9, 0, -22), 10) + repeated((0.95, 0.1, 0, -20), 10)
        var meeting = meeting(frames: frames, segments: [segment(1, 9, "Thank you for watching"), segment(10.5, 19, "Okay, the budget.")])
        // An unaligned source: its context comes from the transcript run, not the unified transcript.
        meeting.tracks[0].offset = nil
        meeting.alignmentReports = [TrackAlignment(trackID: track, method: .unaligned)]
        meeting.highlights = [Highlight(trackID: track, time: 9, text: "Budget")]
        XCTAssertEqual(meeting.highlightContexts().first?.speechContext.map(\.text), ["Okay, the budget."])
    }

    func testIncludingBackgroundAudioMergesLikeAChoice() {
        var base = Meeting(title: "Call")
        base.updatedAt = Date(timeIntervalSince1970: 1)
        var local = base, remote = base
        local.includesBackgroundAudio = true
        local.updatedAt = Date(timeIntervalSince1970: 2)
        remote.notes = "Agenda"
        remote.updatedAt = Date(timeIntervalSince1970: 3)
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
        XCTAssertEqual(merged.includesBackgroundAudio, true)
        XCTAssertEqual(merged.notes, "Agenda")
    }
}
