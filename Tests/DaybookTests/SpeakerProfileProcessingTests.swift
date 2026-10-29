import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// The Mac's processing with speaker profiles: a new recording of a voice the library knows is
/// labelled before its summary is written, so the summary has the name. Temporary library, synthetic
/// audio and embeddings, and a fake inference engine; no models, no microphone.
@MainActor
final class SpeakerProfileProcessingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let me = SyntheticVoice.person(7)

    func testARecordingOfAKnownVoiceIsLabelledBeforeItsSummary() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        // Earlier, the person named themselves in another conversation.
        let earlier = state.newMeeting(title: "Earlier", date: start.addingTimeInterval(-86_400))
        state.update(earlier) { meeting in
            let track = UUID()
            meeting.transcripts = [TrackTranscript(trackID: track, segments: [
                TranscriptSegment(trackID: track, start: 0, end: 60, text: "Hello", speakerID: "earlier:me")])]
            meeting.speakers = [Speaker(id: "earlier:me", name: "Speaker 1", sourceTrackID: track,
                                        embedding: SyntheticVoice.near(self.me, similarity: 0.95, seed: 1), embeddingModelID: FakeInference.voiceSpace)]
            meeting.renameSpeaker(id: "earlier:me", name: "Vlad")
        }
        await state.library.reconcileSpeakerProfiles(options: state.speakerProfileOptions)
        XCTAssertEqual(state.speakerProfiles.map(\.name), ["Vlad"])

        let mic = try rig.audio("mic.wav", frequency: 220)
        try rig.inference.script(mic, [(0, "Let us start"), (5, "The launch is on track"), (10, "Questions next")])
        try rig.inference.voice(mic, SyntheticVoice.near(me, similarity: 0.95, seed: 2))
        let id = try await rig.macConversation("Standup", at: start, seconds: 60, audio: mic)
        state.enqueue(id)
        try await rig.processed(id)

        let speaker = try XCTUnwrap(rig.meeting(id)?.speakers.first)
        XCTAssertEqual(speaker.name, "Vlad")
        XCTAssertEqual(rig.meeting(id)?.speakerIdentity(speaker.id)?.source, .recognized)
        XCTAssertTrue(rig.inference.summarized.last?.contains("Vlad: Let us start") == true, rig.inference.summarized.last ?? "")
    }
}
