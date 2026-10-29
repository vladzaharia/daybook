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

    // MARK: Speakers found without voices

    /// The person named themselves somewhere: Daybook has a profile.
    private func nameVlad(_ state: AppState) async {
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
    }

    /// A conversation processed before voice profiles (a Sortformer run): speakers, no embeddings.
    private func voiceless(_ rig: MultiSourceRig, _ title: String, at date: Date, audio: URL, speakerName: String = "Speaker 1") async throws -> (id: UUID, speaker: String) {
        let id = try await rig.macConversation(title, at: date, seconds: 60, audio: audio)
        let run = UUID(), speaker = "\(run.uuidString):0"
        rig.state.update(id) { meeting in
            let track = meeting.tracks[0].id
            let segments = [TranscriptSegment(trackID: track, start: 0, end: 30, text: "Old words", speakerID: speaker)]
            meeting.transcripts = [TrackTranscript(id: run, trackID: track, segments: segments, modelID: "sortformer",
                                                   processingSettings: ProcessingSettings(modelID: "sortformer"))]
            meeting.unifiedTranscript = segments
            meeting.speakers = [Speaker(id: speaker, name: "Speaker 1", sourceTrackID: track,
                                        analysisSettings: ProcessingSettings(modelID: "sortformer/offline"))]
            meeting.summary = MeetingSummary(overview: "Speaker 1 said the old words.")
            meeting.status = .ready
            if speakerName != "Speaker 1" { meeting.renameSpeaker(id: speaker, name: speakerName) }
        }
        await rig.state.flush()
        return (id, speaker)
    }

    private func installVoiceProfileModel(_ state: AppState) throws {
        let key = try XCTUnwrap(ModelRouting.withDefaultVoiceEmbedder(state.modelSelections, catalog: state.modelCatalog,
                                                                      engines: state.runtime.engines)[.speakerEmbedding])
        state.installedModels.insert(key)
        XCTAssertNotNil(state.voiceProfileModel)
    }

    /// Regression: speakers from runs before voice profiles were never recognized until the person
    /// chose Identify Speakers Again. With a profile in the library, an idle Mac gives them voices from
    /// the saved transcript, and the profiles do the rest; nothing the person named changes.
    func testSpeakersWithoutVoicesGetThemWhenIdleAndKeepTheirNames() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        let mine = try rig.audio("mine.wav", frequency: 330), boss = try rig.audio("boss.wav", frequency: 440)
        try rig.inference.voice(mine, SyntheticVoice.near(me, similarity: 0.95, seed: 3))
        try rig.inference.voice(boss, SyntheticVoice.near(SyntheticVoice.person(9), similarity: 0.95, seed: 4))
        let old = try await voiceless(rig, "Old standup", at: start.addingTimeInterval(-3 * 86_400), audio: mine)
        let named = try await voiceless(rig, "Old 1:1", at: start.addingTimeInterval(-2 * 86_400), audio: boss, speakerName: "Dana")
        try installVoiceProfileModel(state)
        state.giveVoicesWhenIdle()
        XCTAssertNil(state.voicingID, "Without a profile, nothing to recognize them by")

        await nameVlad(state)
        state.giveVoicesWhenIdle()
        try await waitUntil("both conversations' speakers to have voices") {
            state.voicingID == nil && [old, named].allSatisfy { item in rig.meeting(item.id)?.speakers.first?.embedding != nil }
        }
        XCTAssertTrue(rig.inference.transcribed.isEmpty, "Nothing transcribed again")
        let speaker = try XCTUnwrap(rig.meeting(old.id)?.speakers.first)
        XCTAssertEqual(speaker.embeddingModelID, FakeInference.voiceSpace)
        XCTAssertEqual(speaker.analysisSettings?.parameters["voiceEmbeddingModel"], state.voiceProfileModel?.id)
        XCTAssertEqual(rig.meeting(old.id)?.transcripts.count, 1, "The same run")
        XCTAssertEqual(rig.meeting(named.id)?.speakers.first?.name, "Dana")

        await state.library.reconcileSpeakerProfiles(options: state.speakerProfileOptions)
        XCTAssertEqual(rig.meeting(old.id)?.speakers.first?.name, "Vlad")
        XCTAssertEqual(rig.meeting(old.id)?.speakerIdentity(old.speaker)?.source, .recognized)
        XCTAssertEqual(rig.meeting(old.id)?.summary?.overview, "Vlad said the old words.")
        XCTAssertEqual(rig.meeting(named.id)?.speakers.first?.name, "Dana", "The person's name stays")
        XCTAssertEqual(rig.meeting(named.id)?.speakerIdentity(named.speaker)?.source, .named)
        XCTAssertEqual(Set(state.speakerProfiles.map(\.name)), ["Vlad", "Dana"], "And now it teaches a profile")

        // Each run once.
        let embedded = rig.inference.embedded.count
        state.giveVoicesWhenIdle()
        XCTAssertNil(state.voicingID)
        XCTAssertEqual(rig.inference.embedded.count, embedded)
    }

    /// Real work comes first: a job queued while voices are being made stops that, runs, and the
    /// voices are made afterwards.
    func testGivingVoicesGivesWayToQueuedWork() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        let mine = try rig.audio("mine.wav", frequency: 330)
        try rig.inference.voice(mine, SyntheticVoice.near(me, similarity: 0.95, seed: 5))
        let old = try await voiceless(rig, "Old standup", at: start.addingTimeInterval(-3 * 86_400), audio: mine)
        try installVoiceProfileModel(state)
        await nameVlad(state)
        try rig.inference.block(mine)
        state.giveVoicesWhenIdle()
        XCTAssertEqual(state.voicingID, old.id)
        try await waitUntil("voices to be in progress") { rig.inference.isWaiting(on: mine) }

        let mic = try rig.audio("mic.wav", frequency: 220)
        try rig.inference.script(mic, [(0, "New words")])
        let new = try await rig.macConversation("Today", at: start, seconds: 30, audio: mic)
        state.enqueue(new)
        try await rig.processed(new)
        XCTAssertEqual(rig.meeting(new)?.status, .ready)
        XCTAssertNil(rig.meeting(old.id)?.speakers.first?.embedding, "Stopped for the job")

        try rig.inference.unblock(mine)
        state.giveVoicesWhenIdle()
        try await waitUntil("the old conversation's speaker to have a voice") { rig.meeting(old.id)?.speakers.first?.embedding != nil }
    }
}
