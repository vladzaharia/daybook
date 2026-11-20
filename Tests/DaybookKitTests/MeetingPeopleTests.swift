import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// A conversation's people, as both apps' People list them: background voices left out, shares of the talking
/// shown, and the placement picker's automatic item carrying its guess.
final class MeetingPeopleTests: XCTestCase {
    func testBehaviorABackgroundVoiceIsntOneOfThePeopleAndSharesAreOfThoseShown() {
        let track = UUID()
        var meeting = Meeting(title: "Evening call",
                              unifiedTranscript: [TranscriptSegment(trackID: track, start: 0, end: 30, text: "Hello", speakerID: "alex"),
                                                  TranscriptSegment(trackID: track, start: 30, end: 40, text: "Hi", speakerID: "sam")],
                              speakers: [Speaker(id: "tv", name: "Speaker 1"), Speaker(id: "alex", name: "Alex"), Speaker(id: "sam", name: "Sam")])
        // The presenter only ever spoke in what was left out as background audio.
        meeting.backgroundPassages = [TranscriptSegment(trackID: track, start: 40, end: 100, text: "Tonight's news", speakerID: "tv")]
        XCTAssertEqual(meeting.talkTime(of: "alex"), 30)
        XCTAssertEqual(meeting.talkTime(of: "tv"), 0, "background audio isn't talk in the transcript")
        let people = meeting.peopleSpeakers
        XCTAssertEqual(meeting.backgroundOnlySpeakerIDs, ["tv"])
        XCTAssertEqual(people.map(\.speaker.name), ["Alex", "Sam"])
        XCTAssertEqual(people.map(\.index), [1, 2], "inks keep their places")
        XCTAssertEqual(people.first { $0.speaker.id == "alex" }?.share ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(people.first { $0.speaker.id == "sam" }?.share ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertTrue(Meeting(title: "Quiet").peopleSpeakers.isEmpty)
    }

    // MARK: A Mac call: computer audio and the echo-cancelled microphone

    private let system = UUID(), micRaw = UUID(), mic = UUID()
    private let space = "test-voices"
    private var callTracks: [RecordingTrack] {
        [RecordingTrack(id: micRaw, source: .microphone, relativePath: "m.caf", fileName: "Microphone", offset: 0, sha256: "m"),
         RecordingTrack(id: system, source: .systemAudio, relativePath: "s.caf", fileName: "Computer audio", offset: 0, sha256: "s"),
         RecordingTrack(id: mic, source: .microphone, relativePath: "e.caf", fileName: "Microphone (echo-cancelled)", sha256: "e",
                        derivedFrom: micRaw, processing: RecordingTrack.echoCancelledProcessing)]
    }

    /// One recording's processing result: passages (start, label, text) under `run`'s speaker labels, with a voice per label.
    private func output(_ track: UUID, run: String, _ lines: [(Double, String, String)], voices: [String: [Float]]) -> TrackProcessingOutput {
        let segments = lines.map { start, label, text in
            TranscriptSegment(trackID: track, start: start, end: start + 0.4 * Double(text.split(separator: " ").count), text: text,
                              speakerID: "\(run):\(label)", confidence: 0.9)
        }
        let speakers = Set(segments.compactMap(\.speakerID)).sorted().map { id in
            Speaker(id: id, name: "", sourceTrackID: track, embedding: voices[String(id.dropFirst(run.count + 1))], embeddingModelID: space)
        }
        return TrackProcessingOutput(transcript: TrackTranscript(trackID: track, segments: segments, createdAt: Date(timeIntervalSince1970: Double(run.count))),
                                     speakers: speakers, speakerEmbeddingModelID: space, duration: 60)
    }

    private let julia: [Float] = [1, 0, 0, 0], echoOfJulia: [Float] = [0.95, 0.1, 0, 0], vlad: [Float] = [0, 1, 0, 0], blip: [Float] = [0, 0, 1, 0]

    /// The call's side: Julia, and a short second cluster of hers.
    private var callOutput: TrackProcessingOutput {
        output(system, run: "call", [(0, "A", "Thanks for joining me today I wanted to talk about the garden plans"),
                                     (20, "A", "That sounds lovely so let us plant the tomatoes next week"),
                                     (40, "B", "Sorry my connection dropped for a moment there")],
               voices: ["A": julia, "B": blip])
    }

    /// The microphone: Vlad, with some of the call left after echo removal, partly filed under his own voice ("S1"),
    /// partly as a cluster of its own ("S2").
    private func micOutput(run: String) -> TrackProcessingOutput {
        output(mic, run: run, [(0, "S2", "Thanks for joining me today I wanted to talk"),
                               (8, "S1", "Happy to be here I have been thinking about the raised beds all week"),
                               (21.2, "S1", "let us plant the tomatoes next week"),
                               (28, "S1", "Great I will buy the seeds and the soil on Saturday morning")],
               voices: ["S1": vlad, "S2": echoOfJulia])
    }

    private func fuse(_ meeting: inout Meeting) {
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
    }

    /// The report's thirteen rows, in small: every recording's speaker stays in `speakers` (its voice, matches, and
    /// history), but only those the fused transcript gives passages to are people. The microphone's echo cluster matched
    /// to Julia's voice, the microphone's own speaker shown as the owner, and every speaker of a run processed again
    /// say nothing, and aren't listed or counted.
    func testBehaviorSpeakersLeftWithoutPassagesAfterFusionArentPeople() {
        var meeting = Meeting(title: "Call", tracks: callTracks)
        let matching = SpeakerMatchingConfiguration()
        meeting.apply(callOutput, matching: matching, allowSameSource: false)
        meeting.apply(micOutput(run: "mic1"), matching: matching, allowSameSource: false)
        fuse(&meeting)
        XCTAssertEqual(meeting.speakers.map(\.id), ["call:A", "call:B", "mic1:S1", "mic1:S2", "owner"])
        XCTAssertEqual(meeting.speakerMatches?.first { $0.sourceSpeakerID == "mic1:S2" }?.targetSpeakerID, "call:A",
                       "the echo cluster is matched to Julia's voice, and its passages move to her")
        XCTAssertEqual(meeting.talkTime(of: "mic1:S1"), 0, "fusion shows the microphone's own speaker as the owner")
        XCTAssertEqual(meeting.talkTime(of: "mic1:S2"), 0)
        XCTAssertEqual(meeting.peopleSpeakers.map(\.speaker.id), ["call:A", "call:B", "owner"])
        XCTAssertEqual(meeting.peopleLine, "Me", "the byline names the people listed")
        XCTAssertGreaterThan(meeting.talkTime(of: "owner"), 0)
        // Julia's words stay hers; Vlad's are the owner's.
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text.hasPrefix("Thanks for joining") }?.speakerID, "call:A")
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text.hasPrefix("That sounds lovely") }?.speakerID, "call:A")
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text.hasPrefix("Great I will buy") }?.speakerID, "owner")

        // Identify Speakers Again: a new run adds a new set of speakers, matched by voice to the ones here.
        meeting.apply(micOutput(run: "mic2"), matching: matching, allowSameSource: true)
        fuse(&meeting)
        XCTAssertEqual(meeting.speakers.count, 7, "nothing is deleted")
        XCTAssertEqual(meeting.peopleSpeakers.map(\.speaker.id), ["call:A", "call:B", "owner"])
        XCTAssertEqual(Set(meeting.transcriptSpeakers.map(\.id)), ["call:A", "call:B", "owner"])
    }

    /// One person, one row: speakers the person named, confirmed, or Daybook recognized as the same profile are one
    /// person, with their talking added up, under the speaker the person chose (else the owner). A suggestion stays its
    /// own row until it's answered, and turning a label down separates the speaker again.
    func testBehaviorOnePersonFoundTwiceIsOneRowUntilTheLabelIsTakenBack() {
        let track = UUID(), other = UUID(), vladProfile = UUID(), juliaProfile = UUID()
        var meeting = Meeting(title: "Call",
                              unifiedTranscript: [TranscriptSegment(trackID: track, start: 0, end: 30, text: "Hello", speakerID: "owner"),
                                                  TranscriptSegment(trackID: other, start: 30, end: 40, text: "Hi", speakerID: "call:A"),
                                                  TranscriptSegment(trackID: track, start: 40, end: 50, text: "Right", speakerID: "mic:S3"),
                                                  TranscriptSegment(trackID: other, start: 50, end: 55, text: "Mm", speakerID: "call:B")],
                              speakers: [Speaker(id: "call:A", name: "Julia"), Speaker(id: "call:B", name: "Speaker 2"),
                                         Speaker(id: "mic:S1", name: "Vlad"), Speaker(id: "mic:S3", name: "Vlad"), Speaker(id: "owner", name: "Vlad")])
        meeting.fusionSummary = FusionSummary(sources: [], words: 0, corroboratedWords: 0, disputedWords: 0, ownerSpeakerID: "owner")
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "owner", profileID: vladProfile, source: .recognized, appliedName: "Vlad",
                                                   previousName: "Me"), for: "owner")
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "mic:S3", profileID: vladProfile, source: .recognized, appliedName: "Vlad",
                                                   previousName: "Speaker 4"), for: "mic:S3")
        // Silent: the microphone's own speaker, which the owner stands for. Recognized too, never a row.
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "mic:S1", profileID: vladProfile, source: .recognized), for: "mic:S1")
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "call:A", profileID: juliaProfile, source: .named), for: "call:A")
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "call:B", profileID: juliaProfile, source: .suggested), for: "call:B")

        XCTAssertEqual(meeting.samePersonSpeakers, ["owner": "owner", "mic:S3": "owner"])
        let people = meeting.peopleSpeakers
        XCTAssertEqual(people.map(\.speaker.id), ["call:A", "call:B", "owner"])
        XCTAssertEqual(people.map(\.speakerIDs), [["call:A"], ["call:B"], ["owner", "mic:S3"]])
        XCTAssertEqual(people.last?.talkTime, 40)
        XCTAssertEqual(people.last?.index, 4, "the owner's ink")
        XCTAssertEqual(people.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(meeting.peopleLine, "Julia and Vlad")

        // The person names the suggestion's speaker as Julia: one Julia row, under the speaker they named first.
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "call:B", profileID: juliaProfile, source: .confirmed), for: "call:B")
        XCTAssertEqual(meeting.peopleSpeakers.map(\.speakerIDs), [["call:A", "call:B"], ["owner", "mic:S3"]])

        // "Not Vlad" on the second voice: it's no longer Vlad, so it's its own row again.
        meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "mic:S3", profileID: nil, source: .dismissed, rejectedProfileIDs: [vladProfile]),
                                   for: "mic:S3")
        XCTAssertEqual(meeting.peopleSpeakers.map(\.speakerIDs), [["call:A", "call:B"], ["mic:S3"], ["owner"]])
    }

    func testBehaviorTheAutomaticItemCarriesItsGuess() {
        var meeting = Meeting(title: "Sync")
        XCTAssertEqual(meeting.automaticPlacementTitle, "Automatic", "a kind not known yet goes nowhere by guess")
        meeting.summary = MeetingSummary(kind: .general, title: "Sync", overview: "Done")
        XCTAssertEqual(meeting.automaticPlacementTitle, "Work (automatic)")
        meeting.placement = .personal
        XCTAssertEqual(meeting.automaticPlacementTitle, "Work (automatic)", "the person's choice doesn't change the guess")
    }
}
