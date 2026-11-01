import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// What an iPhone processes itself, under the same claims a Mac uses (docs/iphone.md, "Processing on
/// this iPhone"): its own recordings, never a Mac's; never what another device holds; fusion only
/// when every recording is on the timeline; a summary only where it can make one.
final class OnDeviceProcessingTests: XCTestCase {
    private let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    private let mac = ProcessingRequest.Device(id: "mac", name: "Studio Mac")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let all = ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: true)
    private let noSummaries = ProcessingCapabilities(transcribes: true, findsSpeakers: true, summarizes: false)

    private func track(_ name: String) -> RecordingTrack {
        RecordingTrack(source: .microphone, relativePath: "Originals/\(name).m4a", fileName: "\(name).m4a", sha256: name)
    }

    private func device(_ capabilities: ProcessingCapabilities, owning owned: Set<UUID>) -> OnDeviceProcessing.Device {
        OnDeviceProcessing.Device(identity: phone, capabilities: capabilities, owns: { owned.contains($0.id) })
    }

    private func transcript(_ track: RecordingTrack, at date: Date) -> TrackTranscript {
        TrackTranscript(trackID: track.id, segments: [TranscriptSegment(trackID: track.id, start: 0, end: 2, text: "Agenda first.")], createdAt: date)
    }

    private func recorded(_ tracks: [RecordingTrack], request mode: ProcessingRequest.Mode = .newAudio,
                          by requester: ProcessingRequest.Device? = nil) -> (Meeting, ProcessingRequest) {
        var meeting = Meeting(title: "Walk and talk", tracks: tracks, status: .imported)
        let request = ProcessingRequest(meetingID: meeting.id, mode: mode, requestedBy: requester ?? phone, createdAt: now)
        meeting.upsertProcessingRequest(request)
        return (meeting, request)
    }

    func testBehaviorTheIPhoneTranscribesItsOwnRecording() {
        let mine = track("phone")
        let (meeting, request) = recorded([mine])
        XCTAssertEqual(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now), .transcribe([mine.id]))
        XCTAssertEqual(OnDeviceProcessing.next(in: meeting, device: device(all, owning: [mine.id]), at: now)?.work, .transcribe([mine.id]))
    }

    func testBehaviorAMacsRecordingIsntTranscribedOnTheIPhone() {
        let mine = track("phone"), macs = track("mac")
        // Its own request, for a conversation with a Mac's recording still untranscribed.
        let (meeting, request) = recorded([mine, macs])
        XCTAssertNil(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now))
        // A request a Mac (or another device) made is never this iPhone's to run.
        let (other, asked) = recorded([mine], by: mac)
        XCTAssertNil(OnDeviceProcessing.work(for: asked, in: other, device: device(all, owning: [mine.id]), at: now))
    }

    func testBehaviorWorkAnotherDeviceHoldsIsLeftToIt() throws {
        let mine = track("phone")
        var (meeting, request) = recorded([mine])
        let held = try XCTUnwrap(request.claimed(by: mac, at: now, observations: ClaimObservations()))
        meeting.upsertProcessingRequest(held)
        let observations = ClaimObservations()
        XCTAssertFalse(held.isClaimable(by: phone, at: now, observations: observations))
        XCTAssertNil(OnDeviceProcessing.work(for: held, in: meeting, device: device(all, owning: [mine.id]), at: now))
        // A claim this iPhone holds is still its own to carry out.
        let own = try XCTUnwrap(request.claimed(by: phone, at: now))
        meeting.upsertProcessingRequest(own)
        XCTAssertEqual(OnDeviceProcessing.work(for: own, in: meeting, device: device(all, owning: [mine.id]), at: now), .transcribe([mine.id]))
    }

    func testBehaviorWithoutTheSpeakerModelsARecordingWaitsForAMac() {
        let mine = track("phone")
        let (meeting, request) = recorded([mine])
        let speechOnly = ProcessingCapabilities(transcribes: true, findsSpeakers: false, summarizes: false)
        XCTAssertNil(OnDeviceProcessing.work(for: request, in: meeting, device: device(speechOnly, owning: [mine.id]), at: now),
                     "a transcript without speakers would never be redone by a Mac")
        XCTAssertNil(OnDeviceProcessing.work(for: request, in: meeting, device: device(ProcessingCapabilities(transcribes: false, findsSpeakers: false,
                                                                                                             summarizes: false), owning: [mine.id]), at: now))
    }

    func testBehaviorOnceTranscribedItSummarizesHereOnlyWhenItCan() {
        let mine = track("phone")
        var (meeting, request) = recorded([mine])
        meeting.transcripts = [transcript(mine, at: now)]
        XCTAssertTrue(OnDeviceProcessing.fusesHere(meeting), "its one recording starts the timeline")
        XCTAssertEqual(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now), .summarize)
        XCTAssertNil(OnDeviceProcessing.work(for: request, in: meeting, device: device(noSummaries, owning: [mine.id]), at: now),
                     "the summary is a Mac's")
        // Summarize Again from this iPhone runs here when it can summarize, whoever recorded the conversation.
        var (macs, again) = recorded([track("mac")], request: .summaryOnly)
        macs.transcripts = [transcript(macs.tracks[0], at: now)]
        XCTAssertEqual(OnDeviceProcessing.work(for: again, in: macs, device: device(all, owning: []), at: now), .summarize)
        XCTAssertNil(OnDeviceProcessing.work(for: again, in: macs, device: device(noSummaries, owning: []), at: now))
    }

    func testBehaviorARecordingStillToLineUpLeavesFusionToAMac() {
        // A Mac's recording, transcribed there, and this iPhone's, filed to be lined up by its sound.
        let macs = track("mac")
        var mine = track("phone")
        mine.alignment = SourceAlignment(method: .pending)
        var (meeting, request) = recorded([macs, mine])
        meeting.transcripts = [transcript(macs, at: now)]
        XCTAssertEqual(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now), .transcribe([mine.id]),
                       "it transcribes its own recording")
        meeting.transcripts.append(transcript(mine, at: now))
        XCTAssertFalse(OnDeviceProcessing.fusesHere(meeting))
        XCTAssertNil(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now),
                     "the Mac with the other recording lines it up, fuses, and summarizes")
        // Placed, it fuses here: the last recording arrived on this iPhone.
        meeting.tracks[1].alignment = SourceAlignment(method: .audio, offset: 12, confidence: 0.9)
        XCTAssertTrue(OnDeviceProcessing.fusesHere(meeting))
        XCTAssertEqual(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now), .summarize)
    }

    func testBehaviorTranscribingAgainAndFindingSpeakersAgainNeedEveryRecordingToBeItsOwn() {
        let mine = track("phone"), macs = track("mac")
        var (meeting, again) = recorded([mine], request: .fullRetranscription)
        meeting.transcripts = [transcript(mine, at: now.addingTimeInterval(-60))]
        XCTAssertEqual(OnDeviceProcessing.work(for: again, in: meeting, device: device(all, owning: [mine.id]), at: now), .transcribe([mine.id]))
        var (speakers, refresh) = recorded([mine], request: .speakerRefresh)
        speakers.transcripts = [transcript(mine, at: now.addingTimeInterval(-60))]
        XCTAssertEqual(OnDeviceProcessing.work(for: refresh, in: speakers, device: device(all, owning: [mine.id]), at: now), .identifySpeakers([mine.id]))
        var (mixed, retranscribe) = recorded([mine, macs], request: .fullRetranscription)
        mixed.transcripts = [transcript(mine, at: now), transcript(macs, at: now)]
        XCTAssertNil(OnDeviceProcessing.work(for: retranscribe, in: mixed, device: device(all, owning: [mine.id]), at: now))
    }

    func testBehaviorASatisfiedOrFinishedRequestIsNothingToDo() throws {
        let mine = track("phone")
        var (meeting, request) = recorded([mine])
        meeting.transcripts = [transcript(mine, at: now)]
        meeting.setSummary(MeetingSummary(overview: "Plans", modelID: "m", createdAt: now.addingTimeInterval(60)))
        XCTAssertNil(OnDeviceProcessing.work(for: request, in: meeting, device: device(all, owning: [mine.id]), at: now))
        let done = try XCTUnwrap(request.completed(by: mac, at: now))
        XCTAssertNil(OnDeviceProcessing.work(for: done, in: meeting, device: device(all, owning: [mine.id]), at: now))
    }

    func testBehaviorThisDevicesOwnQueueShowsItsWork() {
        let mine = track("phone")
        let (meeting, _) = recorded([mine])
        let running = ProcessingStatus(meeting, queue: .init(running: meeting.id, fraction: 0.4, stage: .identifyingSpeakers), now: now)
        XCTAssertEqual(running, .processing(.init(stage: .identifyingSpeakers, fraction: 0.4)), "here, so no device is named")
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(running: meeting.id, fraction: 0.1, stage: .summarizing), now: now),
                       .processing(.init(stage: .summarizing, fraction: 0.1)), "the queue's stage, without marking the conversation")
        XCTAssertEqual(ProcessingStatus(meeting, queue: .init(paused: [meeting.id]), now: now), .requested(.paused))
    }
}
